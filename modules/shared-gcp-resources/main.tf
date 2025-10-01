# Shared GCP resources that only need to exist once per project
# This module should be instantiated once, and its outputs passed to all pipeline modules

# Random suffix for unique bucket naming
resource "random_id" "suffix" {
  byte_length = 4
}

# Computed resource names
locals {
  source_bucket_name = var.source_bucket_name != "" ? var.source_bucket_name : "gcs-to-s3-gcf-source-${var.project_id}-${random_id.suffix.hex}"
}

# ============== API Enablements ==============
# These are project-level resources that only need to be enabled once

resource "google_project_service" "logging" {
  project                    = var.project_id
  service                    = "logging.googleapis.com"
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "cloudfunctions" {
  project                    = var.project_id
  service                    = "cloudfunctions.googleapis.com"
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "cloudbuild" {
  project                    = var.project_id
  service                    = "cloudbuild.googleapis.com"
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "pubsub" {
  project                    = var.project_id
  service                    = "pubsub.googleapis.com"
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "cloudrun" {
  project                    = var.project_id
  service                    = "run.googleapis.com"
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "cloudscheduler" {
  project                    = var.project_id
  service                    = "cloudscheduler.googleapis.com"
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "eventarc" {
  project                    = var.project_id
  service                    = "eventarc.googleapis.com"
  disable_dependent_services = false
  disable_on_destroy         = false
}

# ============== GCS Service Account for Eventarc ==============
# Project-level service account used by all pipelines

data "google_storage_project_service_account" "gcs_account" {
  project = var.project_id
}

# Grant GCS service account Pub/Sub Publisher role for Eventarc triggers
resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# ============== Function Source Code ==============
# Shared bucket and source code uploads for all pipeline instances

# GCS Bucket for Cloud Functions source code
resource "google_storage_bucket" "function_source" {
  name          = local.source_bucket_name
  location      = var.region
  force_destroy = true # Safe to force destroy - content is versioned in this repo

  uniform_bucket_level_access = true
}

# Create deployment packages
data "archive_file" "transfer_function_source" {
  type        = "zip"
  output_path = "${path.module}/transfer_function.zip"

  source {
    content  = file("${path.module}/function_source/transfer_function.py")
    filename = "main.py"
  }

  source {
    content  = file("${path.module}/function_source/shared.py")
    filename = "shared.py"
  }

  source {
    content  = file("${path.module}/function_source/requirements.txt")
    filename = "requirements.txt"
  }
}

data "archive_file" "cleanup_function_source" {
  type        = "zip"
  output_path = "${path.module}/cleanup_function.zip"

  source {
    content  = file("${path.module}/function_source/cleanup_function.py")
    filename = "main.py"
  }

  source {
    content  = file("${path.module}/function_source/shared.py")
    filename = "shared.py"
  }

  source {
    content  = file("${path.module}/function_source/requirements.txt")
    filename = "requirements.txt"
  }
}

# Upload transfer function source to GCS
resource "google_storage_bucket_object" "transfer_function_source" {
  name   = "transfer-function-${data.archive_file.transfer_function_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.transfer_function_source.output_path
}

# Upload cleanup function source to GCS
resource "google_storage_bucket_object" "cleanup_function_source" {
  name   = "cleanup-function-${data.archive_file.cleanup_function_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.cleanup_function_source.output_path
}
