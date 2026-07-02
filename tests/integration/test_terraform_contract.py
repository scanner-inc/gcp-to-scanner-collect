"""
Terraform contract tests (T1-T2 from the plan). T3 (clean destroy) is
asserted by run.sh after `terraform destroy`.
"""
import subprocess

import pytest

from conftest import ENV_TFVARS, FIXTURE_DIR, gcloud


def test_t1_outputs_consistent_with_reality(tf, gcs, s3):
    """T1: outputs are non-empty and the resources they name actually exist."""
    for key, value in tf.items():
        assert value not in ("", None), f"terraform output {key} is empty"

    # S3 buckets exist and are reachable with our credentials
    s3.head_bucket(Bucket=tf["log_s3_bucket"])
    s3.head_bucket(Bucket=tf["mirror_s3_bucket"])

    # GCS buckets exist
    assert gcs.bucket(tf["log_temp_bucket"]).exists()
    assert gcs.bucket(tf["mirror_source_bucket"]).exists()

    # Run suffix is embedded in created resource names (safety property:
    # everything we made is attributable to this run)
    suffix = tf["run_suffix"]
    for key in ("log_s3_bucket", "mirror_s3_bucket", "log_temp_bucket",
                "mirror_source_bucket", "log_transfer_function", "mirror_function"):
        assert suffix in tf[key], f"{key}={tf[key]} does not embed run suffix {suffix}"


def test_t1b_lifecycle_opt_in_applied(tf, s3):
    """Both created buckets were deployed with s3_expiration_days = 7; the
    lifecycle rule must exist and match."""
    for bucket_key in ("log_s3_bucket", "mirror_s3_bucket"):
        config = s3.get_bucket_lifecycle_configuration(Bucket=tf[bucket_key])
        rules = [r for r in config["Rules"] if r["Status"] == "Enabled"]
        assert any(r.get("Expiration", {}).get("Days") == 7 for r in rules), \
            f"{bucket_key}: expected an enabled 7-day expiration lifecycle rule"


def test_t1c_dlq_and_retry_wiring(tf):
    """The mirror push subscription must have a dead-letter policy and a
    retry policy, and the DLQ pull subscription must exist (a dead-letter
    topic without a subscription silently drops messages)."""
    push = gcloud([
        "pubsub", "subscriptions", "describe", tf["mirror_push_subscription"],
        f"--project={tf['project_id']}",
        "--format=value(deadLetterPolicy.deadLetterTopic,retryPolicy.maximumBackoff)",
    ]).stdout.strip()
    dead_letter_topic, _, max_backoff = push.partition("\t")
    assert dead_letter_topic, "push subscription has no dead-letter policy"
    assert max_backoff, "push subscription has no retry policy"

    dlq = gcloud([
        "pubsub", "subscriptions", "describe", tf["mirror_dlq_subscription"],
        f"--project={tf['project_id']}", "--format=value(name)",
    ]).stdout.strip()
    assert tf["mirror_dlq_subscription"] in dlq, "DLQ pull subscription does not exist"


def test_t2_plan_is_idempotent(tf):
    """T2: a plan right after apply shows no drift (exit code 0)."""
    result = subprocess.run(
        [
            "terraform", f"-chdir={FIXTURE_DIR}", "plan",
            "-detailed-exitcode", "-input=false", "-lock=false",
            f"-var-file={ENV_TFVARS}", f"-var=run_suffix={tf['run_suffix']}",
        ],
        capture_output=True, text=True,
    )
    if result.returncode == 2:
        pytest.fail(f"plan is not idempotent - drift detected:\n{result.stdout[-4000:]}")
    assert result.returncode == 0, f"terraform plan errored:\n{result.stderr[-4000:]}"
