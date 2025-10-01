# Pipeline Identification
variable "name" {
  description = "Name for this pipeline (used to prefix all resource names for easy identification, e.g., 'audit-logs', 'k8s-logs')"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,17}$", var.name))
    error_message = "Name must start with a letter, contain only lowercase letters, numbers, and hyphens, and be 1-18 characters long (required for service account ID to fit within 30 char limit)."
  }
}

# Shared GCP Resources
variable "shared_gcp_resources" {
  description = "Shared GCP resources from the shared-gcp-resources module (pass module.shared_gcp_resources.all)"
  type = object({
    source_bucket             = string
    transfer_object           = string
    cleanup_object            = string
    gcs_service_account_email = string
    enabled_apis              = list(string)
  })
}

# GCP Configuration
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

# AWS Configuration
variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile to use (optional, defaults to default profile)"
  type        = string
  default     = null
}

# Logging Configuration
variable "log_filter" {
  description = "Filter for Cloud Logging sink (empty string = all logs)"
  type        = string
  default     = ""
}

variable "log_prefix" {
  description = "Prefix path for log files in GCS and S3 (e.g., 'logs' or 'audit-logs')"
  type        = string
  default     = "logs"
}

# Cleanup Configuration
variable "age_threshold_minutes" {
  description = "Age threshold in minutes for cleanup function to consider files stale"
  type        = number
  default     = 30
}

# S3 Bucket Configuration
variable "s3_bucket_name" {
  description = "Name for the S3 bucket to create (if not using existing_s3_bucket_name). If empty, generates: logging-s3-target-{account_id}-{random_suffix}"
  type        = string
  default     = ""

  validation {
    condition     = var.s3_bucket_name == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_bucket_name))
    error_message = "s3_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, numbers, dots, hyphens)."
  }

  validation {
    condition     = var.s3_bucket_name == "" || var.existing_s3_bucket_name == ""
    error_message = "Cannot specify both s3_bucket_name and existing_s3_bucket_name. Use one or the other."
  }
}

variable "existing_s3_bucket_name" {
  description = "Use an existing S3 bucket instead of creating a new one (must specify log_prefix, cannot use scanner variables)"
  type        = string
  default     = ""

  validation {
    condition     = var.existing_s3_bucket_name == "" || (var.scanner_sns_topic_arn == "" && var.scanner_role_arn == "")
    error_message = "When using an existing S3 bucket, you cannot specify scanner_sns_topic_arn or scanner_role_arn (configure scanner integration directly in your AWS account)."
  }

  validation {
    condition     = var.existing_s3_bucket_name == "" || var.log_prefix != ""
    error_message = "When using an existing S3 bucket, you must specify a log_prefix to namespace your logs within the bucket."
  }
}

variable "force_destroy_buckets" {
  description = "Allow deletion of non-empty buckets (useful for testing/development)"
  type        = bool
  default     = false
}

# Scanner Integration
variable "scanner_sns_topic_arn" {
  description = "Optional SNS topic ARN for S3 object created notifications (requires scanner_role_arn)"
  type        = string
  default     = ""

  validation {
    condition     = var.scanner_sns_topic_arn == "" || can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:.+$", var.scanner_sns_topic_arn))
    error_message = "scanner_sns_topic_arn must be a valid SNS topic ARN or empty string."
  }
}

variable "scanner_role_arn" {
  description = "Optional scanner role ARN to grant S3 read permissions (requires scanner_sns_topic_arn)"
  type        = string
  default     = ""

  validation {
    condition     = var.scanner_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.scanner_role_arn))
    error_message = "scanner_role_arn must be a valid IAM role ARN or empty string."
  }

  validation {
    condition     = (var.scanner_sns_topic_arn == "") == (var.scanner_role_arn == "")
    error_message = "Both scanner_sns_topic_arn and scanner_role_arn must be specified together, or neither should be specified."
  }
}

# Optional Resource Name Overrides
# If not specified, sensible defaults based on 'name' will be used

variable "gcs_temp_bucket_name" {
  description = "Override name for GCS temporary bucket (default: {name}-temp-{project_id}-{suffix})"
  type        = string
  default     = ""
}

variable "pubsub_topic_id" {
  description = "Override ID for Pub/Sub topic (default: {name}-export-topic-{suffix})"
  type        = string
  default     = ""
}

variable "pubsub_subscription_id" {
  description = "Override ID for Pub/Sub subscription (default: {name}-to-gcs-subscription-{suffix})"
  type        = string
  default     = ""
}

variable "logging_sink_id" {
  description = "Override ID for Cloud Logging sink (default: {name}-export-to-s3-{suffix})"
  type        = string
  default     = ""
}

variable "service_account_id" {
  description = "Override ID for service account (default: {name}-sa-{suffix}, max 30 chars)"
  type        = string
  default     = ""
}

variable "transfer_function_name" {
  description = "Override name for transfer Cloud Function (default: {name}-transfer-{suffix})"
  type        = string
  default     = ""
}

variable "cleanup_function_name" {
  description = "Override name for cleanup Cloud Function (default: {name}-cleanup-{suffix})"
  type        = string
  default     = ""
}

variable "scheduler_job_name" {
  description = "Override name for Cloud Scheduler job (default: {name}-cleanup-scheduler-{suffix})"
  type        = string
  default     = ""
}

variable "aws_role_name" {
  description = "Override name for AWS IAM role (default: gcp-{name}-s3-writer-{suffix})"
  type        = string
  default     = ""
}
