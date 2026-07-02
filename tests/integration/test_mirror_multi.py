"""
Multi-region mirror pipeline test (M9): a US multi-region source bucket
(GCS notifications must work regardless of bucket location) mirroring into
a pre-existing S3 bucket (exercising existing_s3_bucket_name).
"""
import time

from conftest import (
    function_logs_hint,
    s3_get_decompressed,
    s3_object_exists,
    unique_marker,
    wait_for,
)


def test_m9_multiregion_bucket_to_existing_s3(tf, gcs, s3):
    """M9: objects created in a multi-region bucket are mirrored into an
    S3 bucket the module treats as pre-existing."""
    marker = unique_marker()
    source_bucket = gcs.bucket(tf["mirror_multi_source_bucket"])
    s3_bucket = tf["mirror_multi_s3_bucket"]
    prefix = tf["mirror_multi_s3_key_prefix"]

    # This trigger hasn't carried an event yet (the session canary settles
    # the primary mirror's trigger, not this one), so use the same
    # re-upload-until-delivered pattern before asserting content.
    deadline = time.monotonic() + 300
    delivered_key = None
    attempt = 0
    original = ('{"m9": true, "marker": "%s"}\n' % marker).encode() * 50
    while time.monotonic() < deadline and delivered_key is None:
        attempt += 1
        key = f"raw/{marker}/multi-{attempt}.json"
        source_bucket.blob(key).upload_from_string(original)
        try:
            wait_for(
                f"{key} to reach existing S3 bucket",
                lambda k=key: s3_object_exists(s3, s3_bucket, f"{prefix}/{k}"),
                timeout=60,
            )
            delivered_key = key
        except AssertionError:
            continue

    assert delivered_key, (
        "multi-region mirror never delivered an object within 5 minutes. "
        f"{function_logs_hint(tf, 'mirror_multi_function')}"
    )

    # Content round-trips; source untouched
    body, resp = s3_get_decompressed(s3, s3_bucket, f"{prefix}/{delivered_key}")
    assert body == original
    assert resp["Metadata"].get("transferred-by") == "mirror-function"
    assert source_bucket.blob(delivered_key).exists(), "source object must never be deleted"

    # The module must not manage lifecycle on an existing bucket
    try:
        s3.get_bucket_lifecycle_configuration(Bucket=s3_bucket)
        raise AssertionError("existing S3 bucket unexpectedly has a lifecycle configuration")
    except s3.exceptions.ClientError as e:
        assert e.response["Error"]["Code"] == "NoSuchLifecycleConfiguration"
