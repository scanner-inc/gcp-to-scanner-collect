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

# Variables
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "log_filter" {
  description = "Filter for Cloud Logging sink (empty string = all logs)"
  type        = string
  default     = ""
}

variable "age_threshold_minutes" {
  description = "Age threshold in minutes for cleanup function to consider files stale"
  type        = number
  default     = 60
}

# Configure providers
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "aws" {
  region = var.aws_region
}

# Random suffix for unique naming
resource "random_id" "suffix" {
  byte_length = 4
}

# ============== GCP Resources ==============

# Enable required APIs
resource "google_project_service" "logging" {
  service                    = "logging.googleapis.com"
  disable_dependent_services = true
}

resource "google_project_service" "cloudfunctions" {
  service                    = "cloudfunctions.googleapis.com"
  disable_dependent_services = true
}

resource "google_project_service" "cloudbuild" {
  service                    = "cloudbuild.googleapis.com"
  disable_dependent_services = true
}

resource "google_project_service" "pubsub" {
  service                    = "pubsub.googleapis.com"
  disable_dependent_services = true
}

resource "google_project_service" "cloudrun" {
  service                    = "run.googleapis.com"
  disable_dependent_services = true
}

resource "google_project_service" "cloudscheduler" {
  service                    = "cloudscheduler.googleapis.com"
  disable_dependent_services = true
}

resource "google_project_service" "eventarc" {
  service                    = "eventarc.googleapis.com"
  disable_dependent_services = true
}

# GCS Bucket for temporary log batching
resource "google_storage_bucket" "temp_bucket" {
  name          = "logging-temp-${var.project_id}-${random_id.suffix.hex}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 7 # Delete files older than 7 days as safety net
    }
    action {
      type = "Delete"
    }
  }
}

# GCS Bucket for Cloud Functions source code
resource "google_storage_bucket" "function_source_bucket" {
  name          = "gcf-source-${var.project_id}-${random_id.suffix.hex}"
  location      = var.region
  force_destroy = true
}

# Pub/Sub Topic for log sink
resource "google_pubsub_topic" "log_sink_topic" {
  name = "log-export-topic-${random_id.suffix.hex}"

  depends_on = [google_project_service.pubsub]
}

# Pub/Sub Push Subscription to GCS
# Note: This requires setting up a Cloud Storage service agent with proper permissions
# The subscription will batch messages and write them to GCS
resource "google_pubsub_subscription" "log_to_gcs" {
  name  = "log-to-gcs-subscription-${random_id.suffix.hex}"
  topic = google_pubsub_topic.log_sink_topic.name

  # Push to Cloud Storage
  cloud_storage_config {
    bucket = google_storage_bucket.temp_bucket.name
    filename_prefix = "logs/"
    filename_suffix = ".json"

    # Batch settings for ~1-3 minute latency
    max_duration = "60s" # Maximum 1 minutes
    max_bytes    = 10485760 # 10 MB
  }

  depends_on = [
    google_storage_bucket_iam_member.pubsub_gcs_writer
  ]
}

# Grant Pub/Sub service account permission to write to GCS
data "google_project" "project" {}

resource "google_storage_bucket_iam_member" "pubsub_gcs_writer" {
  bucket = google_storage_bucket.temp_bucket.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Cloud Logging Sink to Pub/Sub
resource "google_logging_project_sink" "log_to_pubsub" {
  name        = "log-export-to-s3-${random_id.suffix.hex}"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.log_sink_topic.id}"

  # Filter: empty string means all logs
  filter = var.log_filter

  # Use unique writer identity
  unique_writer_identity = true

  depends_on = [google_project_service.logging]
}

# Grant the log sink's writer identity permission to publish to Pub/Sub
resource "google_pubsub_topic_iam_member" "log_sink_publisher" {
  topic  = google_pubsub_topic.log_sink_topic.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.log_to_pubsub.writer_identity
}

# Service Account for Cloud Functions
resource "google_service_account" "function_sa" {
  account_id   = "logging-to-s3-fn-${random_id.suffix.hex}"
  display_name = "Cloud Function Logging to S3 Service Account"
}

# Grant Function SA access to temporary GCS bucket (read and delete)
resource "google_storage_bucket_iam_member" "function_gcs_admin" {
  bucket = google_storage_bucket.temp_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.function_sa.email}"
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
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.transfer_function_source.output_path
}

# Upload cleanup function source to GCS
resource "google_storage_bucket_object" "cleanup_function_source" {
  name   = "cleanup-function-${data.archive_file.cleanup_function_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.cleanup_function_source.output_path
}

# Primary Transfer Cloud Function (Gen 2)
# Triggered by GCS object creation in temp bucket
resource "google_cloudfunctions2_function" "transfer_function" {
  name     = "log-transfer-${random_id.suffix.hex}"
  location = var.region

  description = "Transfers log files from GCS to S3 with compression handling"

  build_config {
    runtime     = "python311"
    entry_point = "transfer_to_s3"

    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.transfer_function_source.name
      }
    }
  }

  service_config {
    max_instance_count = 10
    min_instance_count = 0
    available_memory   = "512M"
    timeout_seconds    = 540

    environment_variables = {
      AWS_ROLE_ARN  = aws_iam_role.s3_writer_role.arn
      AWS_REGION    = var.aws_region
      TARGET_BUCKET = aws_s3_bucket.target_bucket.id
      GCP_PROJECT   = var.project_id
    }

    service_account_email = google_service_account.function_sa.email
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.storage.object.v1.finalized"
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.function_sa.email

    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.temp_bucket.name
    }
  }

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.cloudrun,
    google_project_service.eventarc
  ]
}

# Cleanup Cloud Function (Gen 2)
# Triggered by Cloud Scheduler every 30 minutes
resource "google_cloudfunctions2_function" "cleanup_function" {
  name     = "log-cleanup-${random_id.suffix.hex}"
  location = var.region

  description = "Retries stale log files older than 1 hour"

  build_config {
    runtime     = "python311"
    entry_point = "cleanup_stale_files"

    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.cleanup_function_source.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    min_instance_count = 0
    available_memory   = "512M"
    timeout_seconds    = 540

    environment_variables = {
      AWS_ROLE_ARN           = aws_iam_role.s3_writer_role.arn
      AWS_REGION             = var.aws_region
      TARGET_BUCKET          = aws_s3_bucket.target_bucket.id
      TEMP_BUCKET            = google_storage_bucket.temp_bucket.name
      GCP_PROJECT            = var.project_id
      AGE_THRESHOLD_MINUTES  = var.age_threshold_minutes
    }

    service_account_email = google_service_account.function_sa.email
  }

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.cloudrun
  ]
}

# Cloud Scheduler Job to trigger cleanup function every 30 minutes
resource "google_cloud_scheduler_job" "cleanup_job" {
  name             = "log-cleanup-scheduler-${random_id.suffix.hex}"
  description      = "Trigger cleanup function every 30 minutes"
  schedule         = "*/30 * * * *"
  time_zone        = "UTC"
  attempt_deadline = "320s"
  region           = var.region

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.cleanup_function.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.function_sa.email
    }
  }

  depends_on = [google_project_service.cloudscheduler]
}

# Grant the function's service account permission to invoke itself
resource "google_cloud_run_service_iam_member" "transfer_invoker" {
  project  = google_cloudfunctions2_function.transfer_function.project
  location = google_cloudfunctions2_function.transfer_function.location
  service  = google_cloudfunctions2_function.transfer_function.name

  role   = "roles/run.invoker"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_cloud_run_service_iam_member" "cleanup_invoker" {
  project  = google_cloudfunctions2_function.cleanup_function.project
  location = google_cloudfunctions2_function.cleanup_function.location
  service  = google_cloudfunctions2_function.cleanup_function.name

  role   = "roles/run.invoker"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

# ============== AWS Resources ==============

# S3 Target Bucket
resource "aws_s3_bucket" "target_bucket" {
  bucket        = "logging-s3-target-${var.aws_account_id}-${random_id.suffix.hex}"
  force_destroy = true
}

# S3 Bucket Versioning
resource "aws_s3_bucket_versioning" "target_bucket_versioning" {
  bucket = aws_s3_bucket.target_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "target_bucket_encryption" {
  bucket = aws_s3_bucket.target_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM Role for GCP Cloud Function to assume via OIDC
resource "aws_iam_role" "s3_writer_role" {
  name = "gcp-logging-s3-writer-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "accounts.google.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "accounts.google.com:sub" = google_service_account.function_sa.unique_id
            "accounts.google.com:aud" = google_service_account.function_sa.unique_id
            "accounts.google.com:oaud" = aws_iam_role.s3_writer_role.arn
          }
        }
      }
    ]
  })
}

# IAM Policy for S3 access
resource "aws_iam_role_policy" "s3_writer_policy" {
  name = "s3-writer-policy-${random_id.suffix.hex}"
  role = aws_iam_role.s3_writer_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:HeadObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.target_bucket.arn,
          "${aws_s3_bucket.target_bucket.arn}/*"
        ]
      }
    ]
  })
}

# ============== Outputs ==============

output "temp_bucket_name" {
  value       = google_storage_bucket.temp_bucket.name
  description = "Name of the GCS temporary batching bucket"
}

output "s3_bucket_name" {
  value       = aws_s3_bucket.target_bucket.id
  description = "Name of the S3 target bucket"
}

output "transfer_function_name" {
  value       = google_cloudfunctions2_function.transfer_function.name
  description = "Name of the transfer Cloud Function"
}

output "cleanup_function_name" {
  value       = google_cloudfunctions2_function.cleanup_function.name
  description = "Name of the cleanup Cloud Function"
}

output "pubsub_topic_name" {
  value       = google_pubsub_topic.log_sink_topic.name
  description = "Name of the Pub/Sub topic"
}

output "log_sink_name" {
  value       = google_logging_project_sink.log_to_pubsub.name
  description = "Name of the Cloud Logging sink"
}

output "aws_role_arn" {
  value       = aws_iam_role.s3_writer_role.arn
  description = "ARN of the AWS IAM role"
}

output "service_account_email" {
  value       = google_service_account.function_sa.email
  description = "Service account email for the functions"
}

output "service_account_unique_id" {
  value       = google_service_account.function_sa.unique_id
  description = "Service account unique ID (for AWS trust policy)"
}

output "test_instructions" {
  value = <<-EOT

  Pipeline deployed successfully!

  Architecture:
  Cloud Logging → Pub/Sub → GCS (temp) → Cloud Function → S3

  To verify the setup:

  1. Check that logs are flowing to Pub/Sub:
     gcloud logging sinks describe ${google_logging_project_sink.log_to_pubsub.name}

  2. Monitor the temporary GCS bucket for log batches:
     gsutil ls gs://${google_storage_bucket.temp_bucket.name}/logs/

  3. Check transfer function logs:
     gcloud functions logs read ${google_cloudfunctions2_function.transfer_function.name} --region=${var.region} --limit=20

  4. Verify logs are appearing in S3:
     aws s3 ls s3://${aws_s3_bucket.target_bucket.id}/logs/ --recursive | head -20

  5. Check cleanup function logs (runs every 30 min):
     gcloud functions logs read ${google_cloudfunctions2_function.cleanup_function.name} --region=${var.region} --limit=10

  Latency: Logs should appear in S3 within 1-3 minutes.

  EOT
}
