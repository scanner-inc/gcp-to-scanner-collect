# Root-level variables
# These can be used by multiple module instances

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

# Default Logging Configuration (can be overridden per-module)
variable "log_filter" {
  description = "Default filter for Cloud Logging sink (empty string = all logs)"
  type        = string
  default     = ""
}

variable "log_prefix" {
  description = "Default prefix path for log files in GCS and S3"
  type        = string
  default     = "logs"
}

# Default S3 Bucket Configuration
variable "s3_bucket_name" {
  description = "Default S3 bucket name (optional)"
  type        = string
  default     = ""
}

variable "existing_s3_bucket_name" {
  description = "Default existing S3 bucket name (optional)"
  type        = string
  default     = ""
}

variable "force_destroy_buckets" {
  description = "Allow deletion of non-empty buckets (useful for testing/development)"
  type        = bool
  default     = false
}

# Default Scanner Integration
variable "scanner_sns_topic_arn" {
  description = "Default SNS topic ARN for S3 object created notifications"
  type        = string
  default     = ""
}

variable "scanner_role_arn" {
  description = "Default scanner role ARN to grant S3 read permissions"
  type        = string
  default     = ""
}
