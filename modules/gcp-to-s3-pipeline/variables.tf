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
