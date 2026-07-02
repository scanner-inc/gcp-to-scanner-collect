# Configure providers
terraform {
  # >= 1.9 required for cross-variable references in variable validation blocks
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Configure providers
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# ============================================================================
# Shared GCP Resources
# ============================================================================
# This module contains resources that only need to exist once per GCP project:
# - API enablements
# - GCS service account permissions
# - Function source bucket and code uploads
#
# All pipeline modules depend on this shared module.

module "shared_gcp_resources" {
  source = "./modules/shared-gcp-resources"

  project_id = var.project_id
  region     = var.region

  # Optional: Override function source bucket name
  # source_bucket_name = "my-custom-gcf-source"
}

# ============================================================================
# Pipeline Modules
# ============================================================================
# Each pipeline instance requires the shared_gcp_resources module above.
# Uncomment the shared module first, then uncomment one or more pipelines below.
#
# Most common configurations are listed first: GCP Audit logs (new or existing bucket).
# Additional log types and advanced examples follow below.

# GCP Audit logs to a new S3 bucket (Scanner integration enabled)
# module "audit_logs_pipeline" {
#   source = "./modules/cloud-logging-to-s3-pipeline"
#
#   name                 = "audit-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter     = "logName:\"cloudaudit.googleapis.com\""
#   log_prefix     = "gcp/audit"
#   # s3_bucket_name = "mycompany-gcp-audit-logs"
#
#   # Optional: expire log objects from the created S3 bucket after N days
#   # s3_expiration_days = 7
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# GCP Audit logs to an existing S3 bucket
# module "audit_logs_to_existing_bucket" {
#   source = "./modules/cloud-logging-to-s3-pipeline"
#
#   name                 = "audit-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter              = "logName:\"cloudaudit.googleapis.com\""
#   log_prefix              = "gcp/audit"
#   existing_s3_bucket_name = "my-existing-scanner-bucket"
#
#   # Cannot use scanner variables with existing bucket
#   # (assume bucket is already configured)
# }

# ============================================================================
# GCS Bucket Mirror Pipelines
# ============================================================================
# Mirror raw logs from existing GCS buckets to S3 so Scanner can index them.
# New objects matching the key filters are copied to S3; source objects are
# never deleted. One module instance per monitored GCS bucket.

# Mirror an existing GCS bucket of raw logs to a new S3 bucket (Scanner integration enabled)
# module "raw_logs_mirror" {
#   source = "./modules/gcs-bucket-to-s3-pipeline"
#
#   name                 = "raw-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   # The existing GCS bucket to monitor
#   gcs_bucket_name = "my-company-raw-logs"
#
#   # Customizable key path filtering (all configured filters must pass):
#   key_prefixes      = ["logs/"]      # only keys under these prefixes
#   # key_include_regex = "\\.json(\\.gz)?$"  # only keys matching this regex
#   key_exclude_regex = "\\.tmp$"      # skip keys matching this regex
#
#   # Namespace mirrored objects within the S3 bucket
#   s3_key_prefix = "gcs/raw-logs"
#
#   # s3_bucket_name = "mycompany-gcs-raw-logs-mirror"  # optional custom name
#
#   # Optional: expire mirrored objects from the created S3 bucket after N days
#   # s3_expiration_days = 7
#
#   # Optional: email alerts when objects land in the dead-letter queue
#   # alert_email = "ops@mycompany.com"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Mirror an existing GCS bucket to an existing S3 bucket
# module "raw_logs_mirror_to_existing_bucket" {
#   source = "./modules/gcs-bucket-to-s3-pipeline"
#
#   name                 = "raw-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   gcs_bucket_name = "my-company-raw-logs"
#   key_prefixes    = ["logs/"]
#   s3_key_prefix   = "gcs/raw-logs"
#
#   existing_s3_bucket_name = "my-existing-scanner-bucket"
#
#   # Cannot use scanner variables with existing bucket
#   # (assume bucket is already configured; lifecycle policy is not managed)
# }

# ============================================================================
# Additional Pipeline Examples
# ============================================================================

# Example: Single pipeline for all logs
# module "all_logs_pipeline" {
#   source = "./modules/cloud-logging-to-s3-pipeline"
#
#   name                 = "all-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#   aws_profile    = var.aws_profile
#
#   log_filter = ""
#   log_prefix = "gcp/all"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Example: Multiple pipelines for different log types
# Uncomment and configure to deploy multiple pipelines

# Pipeline for Kubernetes logs
# module "k8s_logs_pipeline" {
#   source = "./modules/cloud-logging-to-s3-pipeline"
#
#   name                 = "k8s-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter     = "resource.type=\"k8s_container\""
#   log_prefix     = "gcp/k8s"
#   # s3_bucket_name = "mycompany-gcp-k8s-logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Pipeline for Cloud Run logs (includes Cloud Functions Gen 2)
# module "cloudrun_logs_pipeline" {
#   source = "./modules/cloud-logging-to-s3-pipeline"
#
#   name                 = "cloudrun-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter     = "logName:\"run.googleapis.com\""
#   log_prefix     = "gcp/cloudrun"
#   # s3_bucket_name = "mycompany-gcp-cloudrun-logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Example: Using an existing S3 bucket for all logs
# module "logs_to_existing_bucket" {
#   source = "./modules/cloud-logging-to-s3-pipeline"
#
#   name                 = "gcp-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter              = ""
#   log_prefix              = "gcp/all"  # Required when using existing bucket
#   existing_s3_bucket_name = "my-existing-scanner-bucket"
#
#   # Cannot use scanner variables with existing bucket
#   # (assume bucket is already configured)
# }

# Example: Fully customized resource names (pedantic - explicitly name every resource)
# This example shows all 10 per-pipeline resources that get created and how to override their names
# module "custom_names_pipeline" {
#   source = "./modules/cloud-logging-to-s3-pipeline"
#
#   # Required base name (used as fallback for any resources not explicitly named below)
#   name                 = "custom"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter = ""
#   log_prefix = "gcp/custom"
#
#   max_batch_duration_seconds = 60  # Flush logs every 1 minute (more live logs, more files)
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
#
#   # Optional: Explicitly override every single resource name
#   # (normally you'd just rely on the 'name' parameter to prefix everything)
#
#   # GCP Resources (7 total):
#   gcs_temp_bucket_name   = "my-custom-temp-bucket"       # GCS temporary bucket for Pub/Sub batching
#   pubsub_topic_id        = "my-custom-export-topic"      # Pub/Sub topic for Cloud Logging sink
#   pubsub_subscription_id = "my-custom-to-gcs-sub"        # Pub/Sub subscription to write to GCS
#   logging_sink_id        = "my-custom-export-sink"       # Cloud Logging sink to Pub/Sub
#   service_account_id     = "my-custom-sa"                # Service account for Cloud Functions (max 30 chars)
#   transfer_function_name = "my-custom-transfer"          # Primary transfer function (GCS → S3)
#   cleanup_function_name  = "my-custom-cleanup"           # Cleanup function for stale files
#   scheduler_job_name     = "my-custom-cleanup-scheduler" # Cloud Scheduler job for cleanup
#
#   # AWS Resources (2 total):
#   aws_role_name  = "my-custom-gcp-s3-writer" # IAM role for GCP to assume via OIDC
#   s3_bucket_name = "my-custom-s3-bucket"     # S3 target bucket (auto-generated if not specified)
#
#   # Note: The IAM role policy name is automatically derived from aws_role_name as: {aws_role_name}-policy
#   # Note: The function source bucket is shared across all pipelines (see shared_gcp_resources module)
# }
