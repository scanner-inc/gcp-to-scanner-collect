"""
Shared fixtures for the integration test suite.

Assumes the Terraform fixture under fixture/ is already applied (run.sh does
this). All configuration is read from `terraform output -json` - tests never
hardcode environment specifics.
"""
import gzip
import json
import subprocess
import time
import uuid
from pathlib import Path

import boto3
import pytest
from google.cloud import storage

INTEGRATION_DIR = Path(__file__).parent
FIXTURE_DIR = INTEGRATION_DIR / "fixture"
ENV_TFVARS = INTEGRATION_DIR / "env.tfvars"


# ---------- Terraform outputs ----------

@pytest.fixture(scope="session")
def tf():
    """Terraform outputs of the applied fixture, as a flat dict."""
    result = subprocess.run(
        ["terraform", f"-chdir={FIXTURE_DIR}", "output", "-json"],
        capture_output=True, text=True, check=True,
    )
    outputs = json.loads(result.stdout)
    if not outputs:
        pytest.fail("No terraform outputs found - has the fixture been applied? (run.sh does this)")
    return {k: v["value"] for k, v in outputs.items()}


# ---------- Cloud clients ----------

@pytest.fixture(scope="session")
def gcs(tf):
    return storage.Client(project=tf["project_id"])


@pytest.fixture(scope="session")
def s3(tf):
    session = boto3.Session(profile_name=tf["aws_profile"], region_name=tf["aws_region"])
    return session.client("s3")


# ---------- Helpers ----------

def wait_for(description, predicate, timeout, interval=5):
    """Poll predicate until truthy or timeout (seconds). Returns its value."""
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception as e:  # transient API errors count as "not yet"
            last_error = e
        time.sleep(interval)
    detail = f" (last error: {last_error})" if last_error else ""
    raise AssertionError(f"Timed out after {timeout}s waiting for: {description}{detail}")


def s3_object_exists(s3, bucket, key):
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except s3.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == "404":
            return False
        raise


def s3_get_decompressed(s3, bucket, key):
    """Fetch an S3 object, gunzipping if Content-Encoding: gzip. Returns (bytes, response)."""
    resp = s3.get_object(Bucket=bucket, Key=key)
    body = resp["Body"].read()
    if resp.get("ContentEncoding") == "gzip":
        body = gzip.decompress(body)
    return body, resp


def s3_list_keys(s3, bucket, prefix):
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        keys.extend(obj["Key"] for obj in page.get("Contents", []))
    return keys


def gcloud(args, check=True):
    """Run a gcloud command, returning the CompletedProcess."""
    result = subprocess.run(["gcloud", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"gcloud {' '.join(args)} failed:\n{result.stderr[-2000:]}")
    return result


def run_scheduler_job(tf, job_name):
    """Trigger a Cloud Scheduler job immediately (instead of waiting for its cron)."""
    gcloud([
        "scheduler", "jobs", "run", job_name,
        f"--location={tf['region']}", f"--project={tf['project_id']}",
    ])


def function_logs_hint(tf, function_output_key):
    """A copy-pasteable command for debugging a failed arrival."""
    return (
        f"debug: gcloud functions logs read {tf[function_output_key]} "
        f"--project={tf['project_id']} --region={tf['region']} --limit=30"
    )


def unique_marker():
    return uuid.uuid4().hex[:12]


# ---------- Post-apply settle canary ----------

def settle_trigger(gcs_bucket, make_key, s3, s3_bucket, dest_key_of, label, timeout=300):
    """
    Eventarc triggers routinely drop events fired within the first minute or
    two after creation. Push canary objects through a trigger until one
    demonstrably flows to S3, re-uploading every 60s (a fresh object gives a
    fresh event if the previous one was dropped pre-propagation).
    """
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        key = make_key(attempt)
        gcs_bucket.blob(key).upload_from_string(b'{"canary": true}\n')
        try:
            wait_for(
                f"{label} canary {key} to reach S3",
                lambda k=key: s3_object_exists(s3, s3_bucket, dest_key_of(k)),
                timeout=60,
            )
            return  # events are flowing
        except AssertionError:
            continue
    pytest.fail(f"{label} canary never reached S3 within {timeout}s - events are not flowing")


def settle_logging_sink(tf, s3, required_successes=2):
    """A newly-created Cloud Logging sink takes minutes to propagate across
    the Log Router, and entries written during that window can be SILENTLY
    dropped (observed: 1 of 20 entries lost ~7 min after sink creation, with
    no sink_error and a fully-drained Pub/Sub backlog). Write canary entries
    through the REAL path (sink -> Pub/Sub -> GCS batch -> transfer -> S3)
    until `required_successes` consecutive canaries arrive."""
    from google.cloud import logging as gcp_logging

    logger = gcp_logging.Client(project=tf["project_id"]).logger(tf["log_test_log_id"])
    fetched = {}

    def marker_in_s3(marker):
        for key in s3_list_keys(s3, tf["log_s3_bucket"], tf["log_s3_prefix"]):
            if key not in fetched:
                body, _ = s3_get_decompressed(s3, tf["log_s3_bucket"], key)
                fetched[key] = body.decode(errors="replace")
        return any(marker in text for text in fetched.values())

    successes = 0
    attempt = 0
    deadline = time.monotonic() + 600
    while successes < required_successes:
        if time.monotonic() > deadline:
            pytest.fail(
                f"logging sink canary: only {successes}/{required_successes} consecutive "
                "canary entries reached S3 within 10 min - sink still propagating or "
                f"pipeline broken. {function_logs_hint(tf, 'log_transfer_function')}"
            )
        attempt += 1
        marker = f"sink-canary-{unique_marker()}"
        logger.log_struct({"itest_canary": marker, "attempt": attempt})
        try:
            # sink -> Pub/Sub -> 60s max batch -> GCS -> function -> S3
            wait_for(f"sink canary {marker} to reach S3", lambda m=marker: marker_in_s3(m),
                     timeout=150, interval=10)
            successes += 1
        except AssertionError:
            successes = 0  # a dropped canary means the sink is still settling


@pytest.fixture(scope="session", autouse=True)
def pipelines_settled(tf, gcs, s3):
    """Warm every freshly-created delivery mechanism before tests count on it:
    1. the mirror pipeline's notification -> Pub/Sub -> push path,
    2. the logging pipeline's temp-bucket Eventarc trigger (canary uploaded
       straight to the temp bucket),
    3. the Cloud Logging sink itself, end-to-end (a new sink silently drops
       entries until it has propagated across the Log Router)."""
    marker = unique_marker()

    settle_trigger(
        gcs.bucket(tf["mirror_source_bucket"]),
        lambda n: f"logs/canary/{marker}-{n}.json",
        s3, tf["mirror_s3_bucket"],
        lambda k: f"{tf['mirror_s3_key_prefix']}/{k}",
        label="mirror",
    )
    settle_trigger(
        gcs.bucket(tf["log_temp_bucket"]),
        lambda n: f"gcp/itest/canary/{marker}-{n}.jsonl",
        s3, tf["log_s3_bucket"],
        lambda k: k,  # logging pipeline preserves the GCS key in S3
        label="logging temp trigger",
    )
    settle_logging_sink(tf, s3)

    # Canary attempts whose events were dropped strand in the temp bucket
    # (nothing deletes them until the 30-min cleanup); remove them so the
    # temp-bucket-drains test isn't polluted
    temp_bucket = gcs.bucket(tf["log_temp_bucket"])
    for blob in temp_bucket.list_blobs(prefix="gcp/itest/canary/"):
        blob.delete()
