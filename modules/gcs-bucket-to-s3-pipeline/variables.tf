# Pipeline Identification
variable "name" {
  description = "Name prefix for this pipeline's resources (e.g., 'raw-logs', 'lb-logs')"
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
    mirror_object             = string
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
  description = "GCP Region (where the Cloud Functions run)"
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

# Source GCS Bucket Configuration
variable "gcs_bucket_name" {
  description = "Existing GCS bucket to mirror (source objects are never deleted)"
  type        = string
}

variable "max_function_instances" {
  description = "Maximum concurrent mirror function instances (raise for high object volume)"
  type        = number
  default     = 100

  validation {
    condition     = var.max_function_instances >= 1
    error_message = "max_function_instances must be at least 1."
  }
}

variable "dlq_max_delivery_attempts" {
  description = "Delivery attempts (with exponential backoff, 10s-600s) before a notification is dead-lettered"
  type        = number
  default     = 20

  validation {
    condition     = var.dlq_max_delivery_attempts >= 5 && var.dlq_max_delivery_attempts <= 100
    error_message = "dlq_max_delivery_attempts must be between 5 and 100 (Pub/Sub limits)."
  }
}

variable "alert_email" {
  description = "Optional email notified when messages land in the DLQ. Empty = alert policy created without an email channel."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address or empty string."
  }
}

# Key Path Filtering
# All configured filters must pass for an object to be copied to S3.
# Unset filters are skipped (default: everything passes).
variable "key_prefixes" {
  description = "Only copy objects whose key starts with one of these prefixes (e.g., ['logs/']). Filtered server-side, one notification config per prefix. Empty = all keys pass."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.key_prefixes : !can(regex(",", p))])
    error_message = "key_prefixes entries cannot contain commas (they are passed to the Cloud Function as a comma-separated list)."
  }

  validation {
    condition     = length(distinct(var.key_prefixes)) <= 10
    error_message = "At most 10 key_prefixes are supported: each prefix becomes a GCS notification config, and GCS allows at most 10 notification configs per event type per bucket. Use broader prefixes plus key_include_regex/key_exclude_regex for finer filtering."
  }
}

variable "key_include_regex" {
  description = "Only copy objects whose key matches this regex (Python re.search syntax, e.g., '\\.json(\\.gz)?$'). Empty = all keys pass."
  type        = string
  default     = ""
}

variable "key_exclude_regex" {
  description = "Skip objects whose key matches this regex (Python re.search syntax, e.g., '\\.tmp$'). Empty = nothing excluded."
  type        = string
  default     = ""
}

# S3 Destination Configuration
variable "s3_key_prefix" {
  description = "Prefix prepended to object keys when writing to S3 (e.g., 'gcs/raw-logs'). Empty = keep original GCS key."
  type        = string
  default     = ""
}

variable "s3_bucket_name" {
  description = "Name for the S3 bucket to create (if not using existing_s3_bucket_name). If empty, generates: {name}-s3-target-{account_id}-{random_suffix}"
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
  description = "Use an existing S3 bucket instead of creating a new one (cannot use scanner variables; lifecycle policy is not managed)"
  type        = string
  default     = ""

  validation {
    condition     = var.existing_s3_bucket_name == "" || (var.scanner_sns_topic_arn == "" && var.scanner_role_arn == "")
    error_message = "When using an existing S3 bucket, you cannot specify scanner_sns_topic_arn or scanner_role_arn (configure scanner integration directly in your AWS account)."
  }
}

variable "s3_expiration_days" {
  description = "Days after which mirrored objects expire from the created S3 bucket (originals stay in GCS). 0 = retain indefinitely. Ignored for existing buckets."
  type        = number
  default     = 0

  validation {
    condition     = var.s3_expiration_days >= 0
    error_message = "s3_expiration_days must be 0 (infinite retention) or a positive number of days."
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

variable "service_account_id" {
  description = "Override ID for service account (default: {name}-sa-{suffix}, max 30 chars)"
  type        = string
  default     = ""
}

variable "mirror_function_name" {
  description = "Override name for mirror Cloud Function (default: {name}-mirror-{suffix})"
  type        = string
  default     = ""
}

variable "pubsub_topic_id" {
  description = "Override ID for the notification Pub/Sub topic (default: {name}-mirror-topic-{suffix})"
  type        = string
  default     = ""
}

variable "pubsub_subscription_id" {
  description = "Override ID for the push subscription (default: {name}-mirror-push-{suffix})"
  type        = string
  default     = ""
}

variable "dlq_topic_id" {
  description = "Override ID for the dead-letter topic (default: {name}-mirror-dlq-{suffix})"
  type        = string
  default     = ""
}

variable "dlq_subscription_id" {
  description = "Override ID for the dead-letter pull subscription (default: {name}-mirror-dlq-sub-{suffix})"
  type        = string
  default     = ""
}

variable "aws_role_name" {
  description = "Override name for AWS IAM role (default: gcp-{name}-s3-writer-{suffix})"
  type        = string
  default     = ""
}
