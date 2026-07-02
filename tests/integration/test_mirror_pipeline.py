"""
Mirror pipeline tests: GCS object creation -> Pub/Sub notification -> key
filtering -> copy to S3, with the source object left untouched.
"""
import gzip as gz
import time

from conftest import (
    function_logs_hint,
    gcloud,
    s3_get_decompressed,
    s3_object_exists,
    unique_marker,
    wait_for,
)

ARRIVAL_TIMEOUT = 120       # mirror path is event-triggered, no batching
NEGATIVE_GRACE_SECONDS = 45 # extra wait after the positive control lands


def _s3_key(tf, gcs_key):
    return f"{tf['mirror_s3_key_prefix']}/{gcs_key}"


def test_m1_m2_happy_path_and_source_preserved(tf, gcs, s3):
    """M1: matching object is copied to S3 under the key prefix, content
    intact. M2: the source object is never deleted."""
    marker = unique_marker()
    gcs_key = f"logs/{marker}/a.json"
    original = ('{"event": "login", "marker": "%s"}\n' % marker).encode() * 50

    source_bucket = gcs.bucket(tf["mirror_source_bucket"])
    source_bucket.blob(gcs_key).upload_from_string(original)

    wait_for(
        f"{gcs_key} to be mirrored to S3. {function_logs_hint(tf, 'mirror_function')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, gcs_key)),
        timeout=ARRIVAL_TIMEOUT,
    )

    # M1: content round-trips; plain files are gzipped on the fly
    body, resp = s3_get_decompressed(s3, tf["mirror_s3_bucket"], _s3_key(tf, gcs_key))
    assert body == original, "mirrored content differs from source"
    assert resp["ContentEncoding"] == "gzip", "plain files should be gzip-encoded in S3"
    assert resp["Metadata"].get("transferred-by") == "mirror-function"
    assert resp["Metadata"].get("source-bucket") == tf["mirror_source_bucket"]

    # M2: source object still exists in GCS
    assert source_bucket.blob(gcs_key).exists(), "mirror pipeline must NEVER delete source objects"


def test_m3_m4_m5_filters_exclude_non_matching_keys(tf, gcs, s3):
    """M3: wrong prefix is not copied. M4: exclude regex is honored.
    M5: include regex is honored. A positive control bounds the wait."""
    marker = unique_marker()
    control_key = f"logs/{marker}/control.json"
    negatives = [
        f"other/{marker}/b.json",   # M3: outside key_prefixes ["logs/"]
        f"logs/{marker}/c.tmp",     # M4: matches key_exclude_regex \.tmp$
        f"logs/{marker}/d.csv",     # M5: fails key_include_regex \.(json|jsonl)(\.gz)?$
    ]

    source_bucket = gcs.bucket(tf["mirror_source_bucket"])
    for key in negatives:
        source_bucket.blob(key).upload_from_string(b'{"should": "never copy"}')
    source_bucket.blob(control_key).upload_from_string(b'{"control": true}')

    wait_for(
        f"positive control {control_key} to reach S3. {function_logs_hint(tf, 'mirror_function')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, control_key)),
        timeout=ARRIVAL_TIMEOUT,
    )

    # The control (uploaded last) arrived; give stragglers a grace period,
    # then assert the filtered keys never made it.
    time.sleep(NEGATIVE_GRACE_SECONDS)
    for key in negatives:
        assert not s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, key)), \
            f"filtered-out key {key} was wrongly copied to S3"


def test_m7_pre_gzipped_file_copied_byte_for_byte(tf, gcs, s3):
    """M7: a .gz file is copied verbatim - no re-compression, no
    Content-Encoding header (the extension already conveys it)."""
    marker = unique_marker()
    gcs_key = f"logs/{marker}/e.json.gz"
    inner = ('{"marker": "%s"}\n' % marker).encode() * 100
    original_gz = gz.compress(inner)

    gcs.bucket(tf["mirror_source_bucket"]).blob(gcs_key).upload_from_string(original_gz)

    wait_for(
        f"{gcs_key} to be mirrored to S3. {function_logs_hint(tf, 'mirror_function')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, gcs_key)),
        timeout=ARRIVAL_TIMEOUT,
    )

    resp = s3.get_object(Bucket=tf["mirror_s3_bucket"], Key=_s3_key(tf, gcs_key))
    body = resp["Body"].read()
    assert body == original_gz, ".gz files must be copied byte-for-byte"
    assert resp.get("ContentEncoding") is None, ".gz passthrough must not set Content-Encoding"
    assert gz.decompress(body) == inner


def test_m8_gcs_content_encoding_gzip_streamed_raw(tf, gcs, s3):
    """M8: an object stored with GCS content_encoding=gzip metadata is
    streamed to S3 as raw compressed bytes with the encoding preserved."""
    marker = unique_marker()
    gcs_key = f"logs/{marker}/enc.json"
    inner = ('{"m8": true, "marker": "%s"}\n' % marker).encode() * 100
    compressed = gz.compress(inner)

    blob = gcs.bucket(tf["mirror_source_bucket"]).blob(gcs_key)
    blob.content_encoding = "gzip"
    blob.upload_from_string(compressed, content_type="application/json")

    wait_for(
        f"{gcs_key} to be mirrored to S3. {function_logs_hint(tf, 'mirror_function')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, gcs_key)),
        timeout=ARRIVAL_TIMEOUT,
    )

    body, resp = s3_get_decompressed(s3, tf["mirror_s3_bucket"], _s3_key(tf, gcs_key))
    assert resp["ContentEncoding"] == "gzip"
    assert body == inner, "decompressed S3 content differs from original"
    assert resp["Metadata"].get("original-encoding") == "gzip"


def test_m12_redelivery_recovers_from_outage(tf, gcs, s3):
    """M12: Pub/Sub redelivery alone recovers from a delivery outage - there
    is no sweep any more. Block push delivery by revoking the function's
    invoker binding (pushes get 403 and are nacked), upload an object,
    confirm it strands, restore the binding, and verify Pub/Sub's backoff
    redelivery lands the object with no other mechanism involved."""
    service = tf["mirror_function"]
    member = f"serviceAccount:{tf['mirror_service_account']}"
    iam_args = [
        service,
        f"--region={tf['region']}", f"--project={tf['project_id']}",
        f"--member={member}", "--role=roles/run.invoker", "--quiet",
    ]
    source_bucket = gcs.bucket(tf["mirror_source_bucket"])

    gcloud(["run", "services", "remove-iam-policy-binding", *iam_args])
    restored = False
    try:
        # IAM revocation propagates lazily; retry until an upload actually
        # strands (its push delivery is failing)
        blocked_key = None
        for attempt in range(5):
            key = f"logs/{unique_marker()}/redelivery.json"
            source_bucket.blob(key).upload_from_string(b'{"redelivery": true}\n')
            time.sleep(45)
            if not s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, key)):
                blocked_key = key
                break
        assert blocked_key, "could not block delivery: invoker revocation never took effect"

        # Restore delivery and let Pub/Sub's retry backoff (10s-600s) redeliver
        gcloud(["run", "services", "add-iam-policy-binding", *iam_args])
        restored = True

        wait_for(
            f"Pub/Sub redelivery to land {blocked_key} after the outage. "
            f"{function_logs_hint(tf, 'mirror_function')}",
            lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, blocked_key)),
            timeout=660,  # redelivery backoff is capped at 600s
            interval=15,
        )
        resp = s3.head_object(Bucket=tf["mirror_s3_bucket"], Key=_s3_key(tf, blocked_key))
        assert resp["Metadata"].get("transferred-by") == "mirror-function"

        # Source untouched, as always
        assert source_bucket.blob(blocked_key).exists()
    finally:
        if not restored:
            gcloud(["run", "services", "add-iam-policy-binding", *iam_args])
