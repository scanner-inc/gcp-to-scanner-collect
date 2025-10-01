# Single structured output containing all shared resources
# Pass this entire object to pipeline modules via: shared_gcp_resources = module.shared_gcp_resources.all

output "all" {
  description = "All shared GCP resources in a structured object"
  value = {
    # Function source code references
    source_bucket   = google_storage_bucket.function_source.name
    transfer_object = google_storage_bucket_object.transfer_function_source.name
    cleanup_object  = google_storage_bucket_object.cleanup_function_source.name

    # GCS service account (for reference/debugging)
    gcs_service_account_email = data.google_storage_project_service_account.gcs_account.email_address

    # Enabled APIs (for reference/documentation)
    enabled_apis = [
      google_project_service.logging.service,
      google_project_service.cloudfunctions.service,
      google_project_service.cloudbuild.service,
      google_project_service.pubsub.service,
      google_project_service.cloudrun.service,
      google_project_service.cloudscheduler.service,
      google_project_service.eventarc.service,
    ]
  }
}

# Individual outputs for convenience (optional, can use .all instead)
output "source_bucket_name" {
  description = "Name of the shared function source bucket"
  value       = google_storage_bucket.function_source.name
}

output "transfer_function_object" {
  description = "Name of the transfer function source object in GCS"
  value       = google_storage_bucket_object.transfer_function_source.name
}

output "cleanup_function_object" {
  description = "Name of the cleanup function source object in GCS"
  value       = google_storage_bucket_object.cleanup_function_source.name
}
