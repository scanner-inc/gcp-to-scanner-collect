output "gcp_project_info" {
  description = "GCP project information"
  value = {
    project_id     = data.google_project.current.project_id
    project_number = data.google_project.current.number
    project_name   = data.google_project.current.name
  }
}

output "temp_bucket_name" {
  value       = google_storage_bucket.temp_bucket.name
  description = "Name of the GCS temporary batching bucket"
}

output "s3_bucket_name" {
  value       = local.target_bucket_name
  description = "Name of the S3 target bucket"
}

output "transfer_function_name" {
  value       = google_cloudfunctions2_function.transfer_function.name
  description = "Name of the transfer Cloud Function"
}

output "cleanup_function_name" {
  value       = google_cloudfunctions2_function.cleanup_function.name
  description = "Name of the cleanup Cloud Function"
}

output "pubsub_topic_name" {
  value       = google_pubsub_topic.log_sink_topic.name
  description = "Name of the Pub/Sub topic"
}

output "log_sink_name" {
  value       = google_logging_project_sink.log_to_pubsub.name
  description = "Name of the Cloud Logging sink"
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

  Pipeline deployed successfully!

  Architecture:
  Cloud Logging → Pub/Sub → GCS (temp) → Cloud Function → S3

  To verify the setup:

  1. Check that logs are flowing to Pub/Sub:
     gcloud logging sinks describe ${google_logging_project_sink.log_to_pubsub.name}

  2. Monitor the temporary GCS bucket for log batches:
     gsutil ls gs://${google_storage_bucket.temp_bucket.name}/logs/

  3. Check transfer function logs:
     gcloud functions logs read ${google_cloudfunctions2_function.transfer_function.name} --region=${var.region} --limit=20

  4. Verify logs are appearing in S3:
     aws s3 ls s3://${local.target_bucket_name}/${var.log_prefix}/ --recursive | head -20

  5. Check cleanup function logs (runs every 30 min):
     gcloud functions logs read ${google_cloudfunctions2_function.cleanup_function.name} --region=${var.region} --limit=10

  Latency: Logs should appear in S3 within 2-3 minutes.
${local.scanner_sns_provided ? "\n  Scanner Integration:\n  You can now link your AWS bucket '${local.target_bucket_name}' in the scanner AWS account settings.\n" : ""}
  EOT
}
