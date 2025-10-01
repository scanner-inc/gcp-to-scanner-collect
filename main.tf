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

# Example: Single pipeline for all logs
# Uncomment and configure to deploy a single pipeline
# module "all_logs_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
#
#   project_id         = var.project_id
#   region             = var.region
#   aws_account_id     = var.aws_account_id
#   aws_region         = var.aws_region
#   aws_profile        = var.aws_profile
#
#   log_filter         = var.log_filter
#   log_prefix         = var.log_prefix
#   s3_bucket_name     = var.s3_bucket_name
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Optional scanner integration
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Example: Multiple pipelines for different log types
# Uncomment and configure to deploy multiple pipelines

# Pipeline for audit logs
# module "audit_logs_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter     = "logName:\"cloudaudit.googleapis.com\""
#   log_prefix     = "audit-logs"
#   s3_bucket_name = "mycompany-gcp-audit-logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Optional: Enable scanner integration for audit logs
#   # scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   # scanner_role_arn      = var.scanner_role_arn
# }

# Pipeline for Kubernetes logs
# module "k8s_logs_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter     = "resource.type=\"k8s_container\""
#   log_prefix     = "k8s-logs"
#   s3_bucket_name = "mycompany-gcp-k8s-logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
# }

# Pipeline for Cloud Run logs (includes Cloud Functions Gen 2)
# module "cloudrun_logs_pipeline" {
#   source = "./modules/gcp-to-s3-pipeline"
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter     = "protoPayload.serviceName=\"run.googleapis.com\""
#   log_prefix     = "cloudrun-logs"
#   s3_bucket_name = "mycompany-gcp-cloudrun-logs"
#
#   force_destroy_buckets = var.force_destroy_buckets
# }

# Example: Using an existing S3 bucket
# module "logs_to_existing_bucket" {
#   source = "./modules/gcp-to-s3-pipeline"
#
#   project_id     = var.project_id
#   region         = var.region
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   log_filter              = var.log_filter
#   log_prefix              = "gcp-logs"  # Required when using existing bucket
#   existing_s3_bucket_name = "my-existing-scanner-bucket"
#
#   # Cannot use scanner variables with existing bucket
#   # (assume bucket is already configured)
# }
