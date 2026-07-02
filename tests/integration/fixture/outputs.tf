# Everything the pytest driver needs, consumed via `terraform output -json`

output "run_suffix" {
  value = var.run_suffix
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "aws_region" {
  value = var.aws_region
}

output "aws_profile" {
  value = var.aws_profile
}

# --- Cloud Logging pipeline (log-new) ---

output "log_test_log_id" {
  description = "Cloud Logging log ID the sink filter is restricted to"
  value       = local.test_log_id
}

output "log_s3_bucket" {
  value = module.log_new.s3_bucket_name
}

output "log_s3_prefix" {
  value = "gcp/itest"
}

output "log_temp_bucket" {
  value = module.log_new.temp_bucket_name
}

output "log_transfer_function" {
  value = module.log_new.transfer_function_name
}

output "log_cleanup_function" {
  value = module.log_new.cleanup_function_name
}

output "log_cleanup_scheduler_job" {
  value = module.log_new.cleanup_scheduler_job_name
}

output "log_service_account" {
  value = module.log_new.service_account_email
}

# --- Mirror pipeline (mir-new) ---

output "mirror_source_bucket" {
  value = google_storage_bucket.mirror_source.name
}

output "mirror_s3_bucket" {
  value = module.mir_new.s3_bucket_name
}

output "mirror_s3_key_prefix" {
  value = "gcs/mirror"
}

output "mirror_function" {
  value = module.mir_new.mirror_function_name
}

output "mirror_service_account" {
  value = module.mir_new.service_account_email
}

output "mirror_pubsub_topic" {
  value = module.mir_new.pubsub_topic_name
}

output "mirror_push_subscription" {
  value = module.mir_new.push_subscription_name
}

output "mirror_dlq_subscription" {
  value = module.mir_new.dlq_subscription_name
}

output "mirror_alert_policy" {
  value = module.mir_new.alert_policy_name
}

# --- Multi-region mirror pipeline (mir-multi) ---

output "mirror_multi_source_bucket" {
  value = google_storage_bucket.mirror_source_multi.name
}

output "mirror_multi_s3_bucket" {
  value = module.mir_multi.s3_bucket_name
}

output "mirror_multi_s3_key_prefix" {
  value = "gcs/multi"
}

output "mirror_multi_function" {
  value = module.mir_multi.mirror_function_name
}
