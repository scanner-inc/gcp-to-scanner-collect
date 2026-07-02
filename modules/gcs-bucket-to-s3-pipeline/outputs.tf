output "gcp_project_info" {
  description = "GCP project information"
  value = {
    project_id     = data.google_project.current.project_id
    project_number = data.google_project.current.number
    project_name   = data.google_project.current.name
  }
}

output "source_gcs_bucket_name" {
  value       = data.google_storage_bucket.source_bucket.name
  description = "Name of the monitored source GCS bucket"
}

output "s3_bucket_name" {
  value       = local.target_bucket_name
  description = "Name of the S3 target bucket"
}

output "mirror_function_name" {
  value       = google_cloudfunctions2_function.mirror_function.name
  description = "Name of the mirror Cloud Function"
}

output "pubsub_topic_name" {
  value       = google_pubsub_topic.mirror_topic.name
  description = "Topic receiving GCS OBJECT_FINALIZE notifications (replay destination)"
}

output "push_subscription_name" {
  value       = google_pubsub_subscription.mirror_push.name
  description = "Push subscription delivering notifications to the mirror function"
}

output "dlq_topic_name" {
  value       = google_pubsub_topic.dlq_topic.name
  description = "Dead-letter topic for notifications that exhausted delivery attempts"
}

output "dlq_subscription_name" {
  value       = google_pubsub_subscription.dlq_sub.name
  description = "Pull subscription retaining dead-lettered notifications for inspection/replay"
}

output "alert_policy_name" {
  value       = google_monitoring_alert_policy.dlq_alert.name
  description = "Monitoring alert policy that fires when the DLQ is non-empty"
}

output "aws_role_arn" {
  value       = aws_iam_role.s3_writer_role.arn
  description = "ARN of the AWS IAM role"
}

output "service_account_email" {
  value       = google_service_account.function_sa.email
  description = "Service account email for the functions"
}

output "service_account_unique_id" {
  value       = google_service_account.function_sa.unique_id
  description = "Service account unique ID (for AWS trust policy)"
}

output "test_instructions" {
  value = <<-EOT

  GCS bucket mirror pipeline deployed successfully!

  Architecture:
  GCS Bucket (existing) → Pub/Sub (notification) → Cloud Function (filter + copy) → S3
                                   ↳ retries with backoff, dead-letters after ${var.dlq_max_delivery_attempts} attempts

  To verify the setup:

  1. Upload a test object that passes your key filters:
     echo '{"test": true}' | gsutil cp - gs://${data.google_storage_bucket.source_bucket.name}/${length(var.key_prefixes) > 0 ? var.key_prefixes[0] : ""}mirror-test-$(date +%s).json

  2. Check mirror function logs:
     gcloud functions logs read ${google_cloudfunctions2_function.mirror_function.name} --region=${var.region} --limit=20

  3. Verify the object appears in S3:
     aws s3 ls s3://${local.target_bucket_name}/${var.s3_key_prefix != "" ? "${trim(var.s3_key_prefix, "/")}/" : ""} --recursive | head -20

  4. Inspect the dead-letter queue (should be empty):
     gcloud pubsub subscriptions pull ${local.dlq_subscription_id} --limit=10

  Latency: New objects should appear in S3 within seconds to ~1 minute.
${!local.using_existing_bucket && var.s3_expiration_days > 0 ? "\n  Lifecycle: Objects in the S3 bucket expire after ${var.s3_expiration_days} days (originals remain in GCS).\n" : ""}${local.scanner_sns_provided ? "\n  Scanner Integration:\n  You can now link your AWS bucket '${local.target_bucket_name}' in the scanner AWS account settings.\n" : ""}
  EOT
}
