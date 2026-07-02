"""
Cloud Logging pipeline tests (L1-L3 from the plan): log entries -> Pub/Sub
-> GCS batching -> transfer function -> S3.
"""
import json
import time

import pytest
from google.cloud import logging as gcp_logging

from conftest import (
    function_logs_hint,
    s3_get_decompressed,
    s3_list_keys,
    s3_object_exists,
    unique_marker,
    wait_for,
)

NUM_ENTRIES = 20
# sink -> Pub/Sub -> 60s max batch -> GCS -> function -> S3, plus slack for
# first-flush latency variance
ARRIVAL_TIMEOUT = 480


def _extract_seqs(text, marker):
    """Parse JSONL LogEntry lines, returning the set of seq values whose
    jsonPayload carries our marker."""
    seqs = set()
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = entry.get("jsonPayload") or entry.get("json_payload") or {}
        if payload.get("itest_marker") == marker and "seq" in payload:
            seqs.add(int(payload["seq"]))
    return seqs


@pytest.fixture(scope="module")
def delivered(tf, s3):
    """Write NUM_ENTRIES uniquely-marked log entries and wait until every
    one is present in S3. Returns (marker, found_payloads dict)."""
    marker = unique_marker()
    client = gcp_logging.Client(project=tf["project_id"])
    logger = client.logger(tf["log_test_log_id"])
    for i in range(NUM_ENTRIES):
        logger.log_struct({"itest_marker": marker, "seq": i, "msg": f"integration test entry {i}"})

    found_payloads = {}  # s3 key -> (decoded text, response)

    def all_entries_arrived():
        for key in s3_list_keys(s3, tf["log_s3_bucket"], tf["log_s3_prefix"]):
            if key not in found_payloads:
                body, resp = s3_get_decompressed(s3, tf["log_s3_bucket"], key)
                found_payloads[key] = (body.decode(errors="replace"), resp)
        text = "\n".join(t for t, _ in found_payloads.values())
        return _extract_seqs(text, marker) >= set(range(NUM_ENTRIES))

    wait_for(
        f"all {NUM_ENTRIES} marked log entries to reach S3. "
        f"{function_logs_hint(tf, 'log_transfer_function')}",
        all_entries_arrived,
        timeout=ARRIVAL_TIMEOUT,
        interval=15,
    )
    return marker, found_payloads


def test_l1_all_entries_delivered(delivered):
    """L1: every uniquely-marked entry lands in S3 at least once (Pub/Sub is
    at-least-once, so duplicates across batch files are legal)."""
    marker, found_payloads = delivered
    text = "\n".join(t for t, _ in found_payloads.values())
    missing = set(range(NUM_ENTRIES)) - _extract_seqs(text, marker)
    assert not missing, f"entries never reached S3: seqs {sorted(missing)} (marker {marker})"


def test_l2_compression_contract(delivered):
    """L2: transferred objects carry the documented encoding/type/metadata."""
    _, found_payloads = delivered
    assert found_payloads, "no objects to inspect"
    for key, (_, resp) in found_payloads.items():
        assert resp["ContentEncoding"] == "gzip", f"{key}: expected gzip Content-Encoding"
        assert resp["ContentType"] == "application/x-ndjson", f"{key}: unexpected Content-Type"
        assert resp["Metadata"].get("transferred-by") in ("transfer-function", "cleanup-function"), \
            f"{key}: missing/unexpected transferred-by metadata"


def test_l3_temp_bucket_drains(tf, gcs, delivered):
    """L3: the GCS temp bucket empties once transfers complete (objects are
    deleted after successful upload to S3)."""
    bucket = gcs.bucket(tf["log_temp_bucket"])

    def drained():
        # Ignore very fresh files (a new batch may flush mid-check);
        # anything older than 3 minutes should have transferred and been deleted
        stale = [
            b.name for b in bucket.list_blobs()
            if (time.time() - b.time_created.timestamp()) > 180
        ]
        return not stale

    wait_for(
        f"temp bucket {tf['log_temp_bucket']} to drain. "
        f"{function_logs_hint(tf, 'log_transfer_function')}",
        drained,
        timeout=300,
        interval=15,
    )


def test_l5_cleanup_retries_missed_transfer(tf, gcs, s3, delivered):
    """L5: the scheduled cleanup function transfers files the event-triggered
    function missed. Simulates a genuine miss by revoking the transfer
    function's invoker binding (Eventarc delivery then fails), stranding a
    file in the temp bucket, and running the cleanup job while delivery is
    still blocked. Depends on `delivered` so it runs after the happy-path
    tests are done with the pipeline."""
    from conftest import gcloud, run_scheduler_job

    service = tf["log_transfer_function"]
    member = f"serviceAccount:{tf['log_service_account']}"
    iam_args = [
        service,
        f"--region={tf['region']}", f"--project={tf['project_id']}",
        f"--member={member}", "--role=roles/run.invoker", "--quiet",
    ]
    temp_bucket = gcs.bucket(tf["log_temp_bucket"])

    gcloud(["run", "services", "remove-iam-policy-binding", *iam_args])
    try:
        # IAM revocation propagates lazily; retry until an uploaded file
        # actually strands (stays in temp, never reaches S3)
        stranded_key = None
        for attempt in range(5):
            key = f"gcp/itest/manual/stranded-{unique_marker()}.jsonl"
            temp_bucket.blob(key).upload_from_string(b'{"stranded": true}\n')
            time.sleep(45)
            in_temp = temp_bucket.blob(key).exists()
            in_s3 = s3_object_exists(s3, tf["log_s3_bucket"], key)
            if in_temp and not in_s3:
                stranded_key = key
                break
            # Revocation hasn't taken effect yet - the transfer function
            # processed it normally. Clean up and retry.
            if in_s3:
                s3.delete_object(Bucket=tf["log_s3_bucket"], Key=key)
        assert stranded_key, "could not strand a file: invoker revocation never took effect"

        # Run the cleanup job while event delivery is still blocked, so the
        # re-transfer can only have come from the cleanup function
        run_scheduler_job(tf, tf["log_cleanup_scheduler_job"])

        wait_for(
            f"cleanup function to transfer stranded {stranded_key}. "
            f"{function_logs_hint(tf, 'log_cleanup_function')}",
            lambda: s3_object_exists(s3, tf["log_s3_bucket"], stranded_key),
            timeout=240,
            interval=10,
        )
        resp = s3.head_object(Bucket=tf["log_s3_bucket"], Key=stranded_key)
        assert resp["Metadata"].get("transferred-by") == "cleanup-function"

        wait_for(
            "temp copy of the stranded file to be deleted after transfer",
            lambda: not temp_bucket.blob(stranded_key).exists(),
            timeout=120,
        )
    finally:
        gcloud(["run", "services", "add-iam-policy-binding", *iam_args])
