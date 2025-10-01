variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for regional resources"
  type        = string
  default     = "us-central1"
}

variable "source_bucket_name" {
  description = "Override name for GCS function source bucket (default: gcs-to-s3-gcf-source-{project_id}-{suffix})"
  type        = string
  default     = ""
}
