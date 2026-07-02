# Locals
locals {
  scanner_sns_provided  = var.scanner_sns_topic_arn != ""
  scanner_role_provided = var.scanner_role_arn != ""
  using_existing_bucket = var.existing_s3_bucket_name != ""

  # Computed resource names - use override if provided, otherwise use sensible default based on var.name
  service_account_id     = var.service_account_id != "" ? var.service_account_id : "${var.name}-sa-${random_id.suffix.hex}"
  mirror_function_name   = var.mirror_function_name != "" ? var.mirror_function_name : "${var.name}-mirror-${random_id.suffix.hex}"
  pubsub_topic_id        = var.pubsub_topic_id != "" ? var.pubsub_topic_id : "${var.name}-mirror-topic-${random_id.suffix.hex}"
  pubsub_subscription_id = var.pubsub_subscription_id != "" ? var.pubsub_subscription_id : "${var.name}-mirror-push-${random_id.suffix.hex}"
  dlq_topic_id           = var.dlq_topic_id != "" ? var.dlq_topic_id : "${var.name}-mirror-dlq-${random_id.suffix.hex}"
  dlq_subscription_id    = var.dlq_subscription_id != "" ? var.dlq_subscription_id : "${var.name}-mirror-dlq-sub-${random_id.suffix.hex}"
  aws_role_name          = var.aws_role_name != "" ? var.aws_role_name : "gcp-${var.name}-s3-writer-${random_id.suffix.hex}"

  # Key filters passed to the Cloud Function as environment variables
  key_prefixes_csv = join(",", var.key_prefixes)

  # No prefixes configured = one unfiltered notification config
  notification_prefixes = length(var.key_prefixes) > 0 ? toset(var.key_prefixes) : toset([""])
}

# Validate GCP project exists and is accessible
data "google_project" "current" {
  project_id = var.project_id
}

# Validate AWS account matches the configured account ID
data "aws_caller_identity" "current" {}

locals {
  gcp_project_number = data.google_project.current.number
}

# Random suffix for unique naming
# Also carries the AWS account sanity check (preconditions halt the plan with
# a readable message, unlike an unreferenced local)
resource "random_id" "suffix" {
  byte_length = 4

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.aws_account_id
      error_message = <<-EOT
        AWS account ID mismatch: aws_account_id is set to ${var.aws_account_id} but the
        active AWS credentials belong to account ${data.aws_caller_identity.current.account_id}.
        Update aws_account_id in terraform.tfvars, or switch credentials via the
        aws_profile variable / AWS_PROFILE environment variable.
      EOT
    }
  }
}

# ============== GCP Resources ==============
# Note: API enablements and GCS service account are in shared-gcp-resources module

# The existing GCS bucket to monitor (customer-owned, objects are never deleted)
data "google_storage_bucket" "source_bucket" {
  name = var.gcs_bucket_name
}

# GCS service agent (publishes bucket notifications to Pub/Sub)
data "google_storage_project_service_account" "gcs_account" {
  project = var.project_id
}

# Service Account for the Cloud Function (also used by the push subscription's OIDC)
resource "google_service_account" "function_sa" {
  account_id   = local.service_account_id
  display_name = "Cloud Function GCS Bucket to S3 Mirror Service Account"
}

# Grant Function SA read-only access to the monitored bucket
resource "google_storage_bucket_iam_member" "function_gcs_viewer" {
  bucket = data.google_storage_bucket.source_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

# ---------- Notification path: GCS -> Pub/Sub -> push -> function ----------

# Topic receiving OBJECT_FINALIZE notifications from the monitored bucket
resource "google_pubsub_topic" "mirror_topic" {
  name = local.pubsub_topic_id
}

# The GCS service agent must be able to publish notifications to the topic
resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic  = google_pubsub_topic.mirror_topic.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# Notification config(s) on the monitored bucket - one per key prefix, filtered
# server-side. Additive: existing notification configs are untouched.
resource "google_storage_notification" "mirror_notification" {
  for_each = local.notification_prefixes

  bucket             = data.google_storage_bucket.source_bucket.name
  payload_format     = "JSON_API_V1"
  topic              = google_pubsub_topic.mirror_topic.id
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = each.value != "" ? each.value : null

  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# Dead-letter topic: messages that exhaust delivery attempts land here
resource "google_pubsub_topic" "dlq_topic" {
  name = local.dlq_topic_id
}

# A dead-letter topic without a subscription silently drops messages -
# this pull subscription retains them for inspection and replay
resource "google_pubsub_subscription" "dlq_sub" {
  name  = local.dlq_subscription_id
  topic = google_pubsub_topic.dlq_topic.name

  message_retention_duration = "604800s" # 7 days
  expiration_policy {
    ttl = "" # never expire
  }
}

# The Pub/Sub service agent needs these roles for dead-lettering to work
resource "google_pubsub_topic_iam_member" "pubsub_agent_dlq_publisher" {
  topic  = google_pubsub_topic.dlq_topic.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${local.gcp_project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription_iam_member" "pubsub_agent_subscriber" {
  subscription = google_pubsub_subscription.mirror_push.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${local.gcp_project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Push subscription delivering notifications to the mirror function.
# The function acks (204) anything retrying can't fix and nacks (500)
# transient failures; Pub/Sub redelivers with backoff for up to 7 days,
# then dead-letters after max_delivery_attempts.
resource "google_pubsub_subscription" "mirror_push" {
  name  = local.pubsub_subscription_id
  topic = google_pubsub_topic.mirror_topic.name

  ack_deadline_seconds       = 600 # matches the function timeout
  message_retention_duration = "604800s"
  expiration_policy {
    ttl = "" # never expire
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq_topic.id
    max_delivery_attempts = var.dlq_max_delivery_attempts
  }

  push_config {
    push_endpoint = google_cloudfunctions2_function.mirror_function.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.function_sa.email
    }
  }

  depends_on = [
    google_pubsub_topic_iam_member.pubsub_agent_dlq_publisher,
    google_cloud_run_service_iam_member.mirror_invoker,
  ]
}

# ---------- Mirror function ----------

# Mirror Cloud Function (Gen 2, HTTP-triggered via the Pub/Sub push subscription)
resource "google_cloudfunctions2_function" "mirror_function" {
  name     = local.mirror_function_name
  location = var.region

  description = "Copies filter-matching objects from gs://${var.gcs_bucket_name} to S3"

  build_config {
    runtime     = "python311"
    entry_point = "mirror_to_s3"

    source {
      storage_source {
        bucket = var.shared_gcp_resources.source_bucket
        object = var.shared_gcp_resources.mirror_object
      }
    }
  }

  service_config {
    max_instance_count = var.max_function_instances
    min_instance_count = 0
    available_memory   = "512M"
    timeout_seconds    = 540

    environment_variables = {
      AWS_ROLE_ARN      = aws_iam_role.s3_writer_role.arn
      AWS_REGION        = var.aws_region
      TARGET_BUCKET     = local.target_bucket_name
      SOURCE_BUCKET     = data.google_storage_bucket.source_bucket.name
      S3_KEY_PREFIX     = var.s3_key_prefix
      KEY_PREFIXES      = local.key_prefixes_csv
      KEY_INCLUDE_REGEX = var.key_include_regex
      KEY_EXCLUDE_REGEX = var.key_exclude_regex
      GCP_PROJECT       = var.project_id
    }

    service_account_email = google_service_account.function_sa.email
  }
}

# Allow the push subscription's OIDC identity (the function SA) to invoke the function
resource "google_cloud_run_service_iam_member" "mirror_invoker" {
  project  = google_cloudfunctions2_function.mirror_function.project
  location = google_cloudfunctions2_function.mirror_function.location
  service  = google_cloudfunctions2_function.mirror_function.name

  role   = "roles/run.invoker"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

# ---------- DLQ monitoring ----------

# Optional email channel for the DLQ alert
resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "${var.name} mirror pipeline alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

# Fires when any message lands in the DLQ (S3 delivery attempts exhausted)
resource "google_monitoring_alert_policy" "dlq_alert" {
  display_name = "${var.name} mirror DLQ has undelivered messages (${random_id.suffix.hex})"
  combiner     = "OR"

  conditions {
    display_name = "Dead-letter queue depth > 0"

    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${google_pubsub_subscription.dlq_sub.name}\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = var.alert_email != "" ? [google_monitoring_notification_channel.email[0].id] : []

  documentation {
    content = <<-EOT
      Messages from the ${var.name} GCS->S3 mirror pipeline exhausted their
      delivery attempts and landed in the dead-letter queue
      (${local.dlq_subscription_id}). Each message names one GCS object that
      was NOT copied to S3.

      Inspect:  gcloud pubsub subscriptions pull ${local.dlq_subscription_id} --project=${var.project_id} --limit=10
      Replay:   pull messages from the DLQ subscription and republish their
                data to topic ${local.pubsub_topic_id} (the function is
                idempotent - objects already in S3 are skipped).
    EOT
  }
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

# S3 Bucket Lifecycle (optional, only for created bucket)
# Set s3_expiration_days > 0 to expire mirrored objects; off by default.
resource "aws_s3_bucket_lifecycle_configuration" "target_bucket_lifecycle" {
  count  = !local.using_existing_bucket && var.s3_expiration_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.target_bucket[0].id

  rule {
    id     = "expire-mirrored-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = var.s3_expiration_days
    }

    # The bucket is versioned; clean up noncurrent versions shortly after expiry
    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.target_bucket_versioning]
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
            "accounts.google.com:sub"  = google_service_account.function_sa.unique_id
            "accounts.google.com:aud"  = google_service_account.function_sa.unique_id
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
