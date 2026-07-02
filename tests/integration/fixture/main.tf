# Integration test fixture (Phase 1)
#
# Deploys the modules under test into dedicated test accounts:
#   - log-new:  cloud-logging-to-s3-pipeline with an auto-created S3 bucket
#   - mir-new:  gcs-bucket-to-s3-pipeline with all key filters set
#
# Every resource name embeds var.run_suffix so concurrent runs can't collide
# and orphans are attributable to a specific run. Nothing here references
# pre-existing resources; terraform destroy only removes what this fixture
# created.

terraform {
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

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  # Pipeline module names must match ^[a-z][a-z0-9-]{0,17}$
  log_new_name   = "it-${var.run_suffix}-ln"
  mir_new_name   = "it-${var.run_suffix}-mn"
  mir_multi_name = "it-${var.run_suffix}-mm"

  # Cloud Logging log ID the logging tests write to; the sink filter is
  # restricted to it so the pipeline only sees our test entries.
  test_log_id = "it-${var.run_suffix}-log"
}

# ============== Shared GCP resources ==============

module "shared_gcp_resources" {
  source = "../../../modules/shared-gcp-resources"

  project_id = var.project_id
  region     = var.region
}

# ============== Cloud Logging pipeline under test ==============

module "log_new" {
  source = "../../../modules/cloud-logging-to-s3-pipeline"

  name                 = local.log_new_name
  shared_gcp_resources = module.shared_gcp_resources.all

  project_id     = var.project_id
  region         = var.region
  aws_account_id = var.aws_account_id
  aws_region     = var.aws_region

  log_filter = "logName=\"projects/${var.project_id}/logs/${local.test_log_id}\""
  log_prefix = "gcp/itest"

  # Fastest allowed flush so tests don't wait on batching
  max_batch_duration_seconds = 60

  # Exercises the lifecycle opt-in path (asserted by the contract tests)
  s3_expiration_days = 7

  # Age 0 so the on-demand cleanup-retry test doesn't wait 30 minutes for a
  # stranded file to count as stale
  age_threshold_minutes = 0

  force_destroy_buckets = true
}

# ============== GCS mirror pipeline under test ==============

# Stand-in for a customer-owned bucket of raw logs. Created by the fixture,
# monitored (never deleted from) by the module under test.
resource "google_storage_bucket" "mirror_source" {
  name          = "it-${var.run_suffix}-mirror-src-${var.project_id}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true
}

module "mir_new" {
  source = "../../../modules/gcs-bucket-to-s3-pipeline"

  # The module reads the source bucket via a data source; when the bucket is
  # created in the same configuration (as here), defer that read to apply
  depends_on = [google_storage_bucket.mirror_source]

  name                 = local.mir_new_name
  shared_gcp_resources = module.shared_gcp_resources.all

  project_id     = var.project_id
  region         = var.region
  aws_account_id = var.aws_account_id
  aws_region     = var.aws_region

  gcs_bucket_name = google_storage_bucket.mirror_source.name

  # All three filter mechanisms in play, so tests can cover each
  key_prefixes      = ["logs/"]
  key_include_regex = "\\.(json|jsonl)(\\.gz)?$"
  key_exclude_regex = "\\.tmp$"

  s3_key_prefix      = "gcs/mirror"
  s3_expiration_days = 7

  # No alert_email: the DLQ alert policy is still created (asserted by the
  # contract tests), just without an email channel

  force_destroy_buckets = true
}

# ============== Multi-region mirror pipeline under test ==============
# Exercises two paths the primary mirror instance doesn't:
#   - a US multi-region source bucket (notifications must flow regardless
#     of bucket location)
#   - existing_s3_bucket_name (fixture-created, handed to the module as
#     "existing"; module must not manage lifecycle/notifications on it)

resource "google_storage_bucket" "mirror_source_multi" {
  name          = "it-${var.run_suffix}-mirror-multi-${var.project_id}"
  location      = "US" # multi-region
  force_destroy = true

  uniform_bucket_level_access = true
}

# Stand-in for a customer's pre-existing S3 bucket
resource "aws_s3_bucket" "mirror_existing_target" {
  bucket        = "it-${var.run_suffix}-mirror-existing-${var.aws_account_id}"
  force_destroy = true
}

module "mir_multi" {
  source = "../../../modules/gcs-bucket-to-s3-pipeline"

  depends_on = [google_storage_bucket.mirror_source_multi, aws_s3_bucket.mirror_existing_target]

  name                 = local.mir_multi_name
  shared_gcp_resources = module.shared_gcp_resources.all

  project_id     = var.project_id
  region         = var.region
  aws_account_id = var.aws_account_id
  aws_region     = var.aws_region

  gcs_bucket_name = google_storage_bucket.mirror_source_multi.name

  # No filters: everything mirrors
  s3_key_prefix           = "gcs/multi"
  existing_s3_bucket_name = aws_s3_bucket.mirror_existing_target.bucket

  force_destroy_buckets = true
}
