# Locals
locals {
  scanner_sns_provided  = var.scanner_sns_topic_arn != ""
  scanner_role_provided = var.scanner_role_arn != ""
  using_existing_bucket = var.existing_s3_bucket_name != ""

  # Computed resource names - use override if provided, otherwise use sensible default based on var.name
  gcs_temp_bucket_name      = var.gcs_temp_bucket_name != "" ? var.gcs_temp_bucket_name : "${var.name}-temp-${var.project_id}-${random_id.suffix.hex}"
  pubsub_topic_id           = var.pubsub_topic_id != "" ? var.pubsub_topic_id : "${var.name}-export-topic-${random_id.suffix.hex}"
  pubsub_subscription_id    = var.pubsub_subscription_id != "" ? var.pubsub_subscription_id : "${var.name}-to-gcs-subscription-${random_id.suffix.hex}"
  logging_sink_id           = var.logging_sink_id != "" ? var.logging_sink_id : "${var.name}-export-to-s3-${random_id.suffix.hex}"
  service_account_id        = var.service_account_id != "" ? var.service_account_id : "${var.name}-sa-${random_id.suffix.hex}"
  transfer_function_name    = var.transfer_function_name != "" ? var.transfer_function_name : "${var.name}-transfer-${random_id.suffix.hex}"
  cleanup_function_name     = var.cleanup_function_name != "" ? var.cleanup_function_name : "${var.name}-cleanup-${random_id.suffix.hex}"
  scheduler_job_name        = var.scheduler_job_name != "" ? var.scheduler_job_name : "${var.name}-cleanup-scheduler-${random_id.suffix.hex}"
  aws_role_name             = var.aws_role_name != "" ? var.aws_role_name : "gcp-${var.name}-s3-writer-${random_id.suffix.hex}"
}

# Validate GCP project exists and is accessible
data "google_project" "current" {
  project_id = var.project_id
}

# Validate AWS account matches the configured account ID
data "aws_caller_identity" "current" {}

locals {
  gcp_project_number = data.google_project.current.number

  # Validate AWS account ID matches
  aws_account_mismatch_error = data.aws_caller_identity.current.account_id != var.aws_account_id ? file(<<-EOT

    ╔═══════════════════════════════════════════════════════════════════════╗
    ║                    AWS ACCOUNT ID MISMATCH ERROR                      ║
    ╚═══════════════════════════════════════════════════════════════════════╝

    Configured in tfvars: ${var.aws_account_id}
    Active AWS account:   ${data.aws_caller_identity.current.account_id}

    Please either:
      1. Update aws_account_id in terraform.tfvars to match your active AWS account
      2. Switch to the correct AWS profile using 'aws_profile' variable
      3. Set AWS_PROFILE environment variable

  EOT
  ) : null
}

# Random suffix for unique naming
resource "random_id" "suffix" {
  byte_length = 4
}

# ============== GCP Resources ==============
# Note: API enablements and GCS service account are now in shared-gcp-resources module

# GCS Bucket for temporary log batching
resource "google_storage_bucket" "temp_bucket" {
  name          = local.gcs_temp_bucket_name
  location      = var.region
  force_destroy = var.force_destroy_buckets

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

# Pub/Sub Topic for log sink
resource "google_pubsub_topic" "log_sink_topic" {
  name = local.pubsub_topic_id
}

# Pub/Sub Push Subscription to GCS
# Note: This requires setting up a Cloud Storage service agent with proper permissions
# The subscription will batch messages and write them to GCS
resource "google_pubsub_subscription" "log_to_gcs" {
  name  = local.pubsub_subscription_id
  topic = google_pubsub_topic.log_sink_topic.name

  # Push to Cloud Storage
  cloud_storage_config {
    bucket                   = google_storage_bucket.temp_bucket.name
    filename_prefix          = "${var.log_prefix}/"
    filename_suffix          = ".jsonl"
    filename_datetime_format = "YYYY/MM/DD/hh/mm_ssZ_"

    # Batch settings for better aggregation
    # Flushes when EITHER condition is met (max_duration OR 10MB)
    max_duration = "${var.max_batch_duration_seconds}s"
    max_bytes    = 10485760 # 10 MB
  }

  depends_on = [
    google_storage_bucket_iam_member.pubsub_gcs_writer,
    google_storage_bucket_iam_member.pubsub_gcs_reader
  ]
}

# Grant Pub/Sub service account permission to write to GCS
data "google_project" "project" {}

resource "google_storage_bucket_iam_member" "pubsub_gcs_writer" {
  bucket = google_storage_bucket.temp_bucket.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "pubsub_gcs_reader" {
  bucket = google_storage_bucket.temp_bucket.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Cloud Logging Sink to Pub/Sub
resource "google_logging_project_sink" "log_to_pubsub" {
  name        = local.logging_sink_id
  destination = "pubsub.googleapis.com/${google_pubsub_topic.log_sink_topic.id}"

  # Filter: empty string means all logs
  filter = var.log_filter

  # Use unique writer identity
  unique_writer_identity = true
}

# Grant the log sink's writer identity permission to publish to Pub/Sub
resource "google_pubsub_topic_iam_member" "log_sink_publisher" {
  topic  = google_pubsub_topic.log_sink_topic.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.log_to_pubsub.writer_identity
}

# Service Account for Cloud Functions
resource "google_service_account" "function_sa" {
  account_id   = local.service_account_id
  display_name = "Cloud Function Logging to S3 Service Account"
}

# Grant Function SA access to temporary GCS bucket (read and delete)
resource "google_storage_bucket_iam_member" "function_gcs_admin" {
  bucket = google_storage_bucket.temp_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

# Grant Function SA permission to receive Eventarc events
resource "google_project_iam_member" "function_eventarc_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# Primary Transfer Cloud Function (Gen 2)
# Triggered by GCS object creation in temp bucket
resource "google_cloudfunctions2_function" "transfer_function" {
  name     = local.transfer_function_name
  location = var.region

  description = "Transfers log files from GCS to S3 with compression handling"

  build_config {
    runtime     = "python311"
    entry_point = "transfer_to_s3"

    source {
      storage_source {
        bucket = var.shared_gcp_resources.source_bucket
        object = var.shared_gcp_resources.transfer_object
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
      TARGET_BUCKET = local.target_bucket_name
      TEMP_BUCKET   = google_storage_bucket.temp_bucket.name
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
    google_project_iam_member.function_eventarc_receiver
  ]
}

# Cleanup Cloud Function (Gen 2)
# Triggered by Cloud Scheduler every 30 minutes
resource "google_cloudfunctions2_function" "cleanup_function" {
  name     = local.cleanup_function_name
  location = var.region

  description = "Retries stale log files older than 1 hour"

  build_config {
    runtime     = "python311"
    entry_point = "cleanup_stale_files"

    source {
      storage_source {
        bucket = var.shared_gcp_resources.source_bucket
        object = var.shared_gcp_resources.cleanup_object
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
      TARGET_BUCKET          = local.target_bucket_name
      TEMP_BUCKET            = google_storage_bucket.temp_bucket.name
      GCP_PROJECT            = var.project_id
      AGE_THRESHOLD_MINUTES  = var.age_threshold_minutes
    }

    service_account_email = google_service_account.function_sa.email
  }
}

# Cloud Scheduler Job to trigger cleanup function every 30 minutes
resource "google_cloud_scheduler_job" "cleanup_job" {
  name             = local.scheduler_job_name
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

# Data source for existing S3 bucket (if specified)
data "aws_s3_bucket" "existing_bucket" {
  count  = local.using_existing_bucket ? 1 : 0
  bucket = var.existing_s3_bucket_name
}

# S3 Target Bucket (only create if not using existing)
resource "aws_s3_bucket" "target_bucket" {
  count         = local.using_existing_bucket ? 0 : 1
  bucket        = var.s3_bucket_name != "" ? var.s3_bucket_name : "${var.name}-s3-target-${var.aws_account_id}-${random_id.suffix.hex}"
  force_destroy = var.force_destroy_buckets
}

# S3 Bucket Versioning (only for created bucket)
resource "aws_s3_bucket_versioning" "target_bucket_versioning" {
  count  = local.using_existing_bucket ? 0 : 1
  bucket = aws_s3_bucket.target_bucket[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket Encryption (only for created bucket)
resource "aws_s3_bucket_server_side_encryption_configuration" "target_bucket_encryption" {
  count  = local.using_existing_bucket ? 0 : 1
  bucket = aws_s3_bucket.target_bucket[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 Bucket Notification Configuration (only for created bucket with scanner integration)
resource "aws_s3_bucket_notification" "scanner_notification" {
  count  = !local.using_existing_bucket && local.scanner_sns_provided ? 1 : 0
  bucket = aws_s3_bucket.target_bucket[0].id

  topic {
    topic_arn = var.scanner_sns_topic_arn
    events    = ["s3:ObjectCreated:*"]
  }
}

# Local variable to reference the bucket name (works for both created and existing)
locals {
  target_bucket_name = local.using_existing_bucket ? var.existing_s3_bucket_name : aws_s3_bucket.target_bucket[0].id
  target_bucket_arn  = local.using_existing_bucket ? data.aws_s3_bucket.existing_bucket[0].arn : aws_s3_bucket.target_bucket[0].arn
}

# IAM Role for GCP Cloud Function to assume via OIDC
resource "aws_iam_role" "s3_writer_role" {
  name = local.aws_role_name

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
            "accounts.google.com:oaud" = "arn:aws:iam::${var.aws_account_id}:role/${local.aws_role_name}"
          }
        }
      }
    ]
  })
}

# IAM Policy for S3 access
resource "aws_iam_role_policy" "s3_writer_policy" {
  name = "${local.aws_role_name}-policy"
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
          local.target_bucket_arn,
          "${local.target_bucket_arn}/*"
        ]
      }
    ]
  })
}

# IAM Policy for Scanner Role to read from S3 (only for created bucket)
resource "aws_iam_role_policy" "scanner_read_policy" {
  count = !local.using_existing_bucket && local.scanner_role_provided ? 1 : 0
  name  = "${var.name}-scanner-s3-read-policy-${random_id.suffix.hex}"
  role  = split("/", var.scanner_role_arn)[1]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketNotification",
          "s3:GetEncryptionConfiguration",
          "s3:ListBucket",
          "s3:GetObject",
          "s3:GetObjectTagging"
        ]
        Resource = [
          local.target_bucket_arn,
          "${local.target_bucket_arn}/*"
        ]
      }
    ]
  })
}

