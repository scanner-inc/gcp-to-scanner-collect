# Configure providers
terraform {
  required_version = ">= 1.0"
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

# Example: Single pipeline for all logs
# Uncomment and configure to deploy a single pipeline
# module "all_logs_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
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
#   log_prefix = "logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Example: Multiple pipelines for different log types
# Uncomment and configure to deploy multiple pipelines

# Pipeline for audit logs
# module "audit_logs_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
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
#   log_prefix     = "audit-logs"
#   # s3_bucket_name = "mycompany-gcp-audit-logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Pipeline for Kubernetes logs
# module "k8s_logs_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
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
#   log_prefix     = "k8s-logs"
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
#   source = "./modules/gcp-to-s3-pipeline"
#
#   name                 = "cloudrun-logs"
#   shared_gcp_resources = module.shared_gcp_resources.all
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter     = "protoPayload.serviceName=\"run.googleapis.com\""
#   log_prefix     = "cloudrun-logs"
#   # s3_bucket_name = "mycompany-gcp-cloudrun-logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Example: Using an existing S3 bucket
# module "logs_to_existing_bucket" {
#   source = "./modules/gcp-to-s3-pipeline"
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
#   log_prefix              = "gcp-logs"  # Required when using existing bucket
#   existing_s3_bucket_name = "my-existing-scanner-bucket"
#
#   # Cannot use scanner variables with existing bucket
#   # (assume bucket is already configured)
# }

# Example: Fully customized resource names (pedantic - explicitly name every resource)
# This example shows all 10 per-pipeline resources that get created and how to override their names
# module "custom_names_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
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
#   log_prefix = "custom-logs"
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
