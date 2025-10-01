# GCP Logging to S3 Pipeline

Automated pipeline that exports GCP Cloud Logging logs to Amazon S3 with configurable latency (default 2-3 minutes). Logs are batched in GCS temporarily, then transferred to S3 with efficient compression handling.

## Overview

This project deploys a serverless architecture that streams GCP logs to S3 via Pub/Sub and GCS. Logs are written to Pub/Sub by a Cloud Logging sink, batched into GCS by a push subscription, then transferred to S3 by a Cloud Function. A secondary cleanup function runs every 30 minutes to handle any failed transfers.

## Architecture

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│ Cloud Logging│ ───► │  Pub/Sub     │ ───► │  GCS Bucket  │ ───► │ Cloud        │ ───► │  S3 Bucket   │
│    Sink      │      │  Topic +     │      │  (Temporary  │      │ Function     │      │  (Target)    │
│              │      │ Push Sub     │      │   Batching)  │      │ (Transfer +  │      │              │
│              │      │              │      │              │      │  Delete)     │      │              │
└──────────────┘      └──────────────┘      └──────────────┘      └──────────────┘      └──────────────┘
   Log Entries           Batched              Batch Files          Download,                Compressed
   (all logs)           Messages              (gzipped)            Upload, Delete           Log Files
                                                                        ▲
                                                                        │
                                                                        │ Retry stale files
                                                              ┌──────────────────┐
                                                              │  Cloud Scheduler │
                                                              │  (Every 30 min)  │
                                                              │  Cleanup missed  │
                                                              │  files > 1 hr    │
                                                              └──────────────────┘
```

### Key Components

- **Cloud Logging Sink**: Routes all logs (or filtered logs) to Pub/Sub topic
- **Pub/Sub Topic + Push Subscription**: Batches log entries and writes to GCS
- **GCS Temporary Bucket**: Stores batched logs temporarily before S3 transfer
- **Primary Cloud Function**: Triggered on GCS object creation, transfers to S3 with compression handling, deletes from GCS on success
- **Cleanup Cloud Function**: Runs every 30 minutes via Cloud Scheduler to retry stale files (>1 hour old)
- **Workload Identity Federation**: Uses OIDC/JWT tokens from GCP metadata server to assume AWS role (no credentials required)
- **S3 Target Bucket**: Final destination for compressed log files with versioning and encryption

## Features

- **Flexible S3 Configuration**: Create a new S3 bucket with a custom name, use an existing bucket, or let Terraform auto-generate a bucket name
- **Scanner Integration**: Optional configuration to automatically set up S3 notifications and IAM policies for security scanner integration
- **Efficient Compression**: Automatically handles gzip compression for log files during transfer
- **Automatic Cleanup**: Retry mechanism for failed transfers via scheduled Cloud Function

## Prerequisites

- Terraform >= 1.0
- Google Cloud SDK (`gcloud`)
- AWS CLI (`aws`)
- Active GCP project with billing enabled
- AWS account with appropriate permissions
- Configured credentials for both clouds

## Setup

This project supports two deployment modes:

1. **Single Pipeline** - Deploy one pipeline for all logs or a specific log filter
2. **Multiple Pipelines** - Deploy separate pipelines for different log types (audit logs, K8s logs, function logs, etc.)

### 1. Configure Variables

Copy `terraform.tfvars.example` to `terraform.tfvars`:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your configuration
```

#### Required Variables

- `project_id`: Your GCP project ID
- `aws_account_id`: Your AWS account ID
- `region`: GCP region (default: `us-central1`)
- `aws_region`: AWS region (default: `us-east-1`)

### 2. Configure Your Pipeline(s)

#### Step 1: Enable Shared Resources

Note the `shared_gcp_resources` module in `main.tf`. This module contains resources that only need to exist once per GCP project:
- API enablements (7 APIs)
- GCS service account IAM permissions
- Function source bucket and code uploads

#### Step 2: Configure Pipeline Module(s)

Then uncomment one or more pipeline module configurations:

- **Single pipeline** (`all_logs_pipeline`): Captures all logs to one S3 bucket
- **Multiple pipelines** (`audit_logs_pipeline`, `k8s_logs_pipeline`, etc.): Separates different log types into different S3 buckets
- **Existing S3 bucket** (`logs_to_existing_bucket`): Uses a pre-existing S3 bucket
- **Custom resource names** (`custom_names_pipeline`): Shows all resources and how to override their names

Each pipeline module requires:
- `name`: Unique identifier for this pipeline (prefixes all per-pipeline resources)
- `shared_gcp_resources`: Pass `module.shared_gcp_resources.all`

See `main.tf` for detailed examples with inline documentation.

#### Module Configuration Options

Each pipeline module instance supports:

**Required:**
- `name`: Name for this pipeline (used to prefix all resource names for easy identification, e.g., 'audit-logs', 'k8s-logs')
  - Must start with a letter, contain only lowercase letters, numbers, and hyphens
  - 1-18 characters long
  - This name will be used to prefix all per-pipeline GCP and AWS resources
- `shared_gcp_resources`: Shared GCP resources object from `module.shared_gcp_resources.all`

**S3 Bucket Options (choose one):**
- `s3_bucket_name`: Create a new bucket with a custom name
- `existing_s3_bucket_name`: Use an existing S3 bucket (must also set `log_prefix`)
- Neither: Auto-generates bucket name as `{name}-s3-target-{account_id}-{random_suffix}`

**Scanner Integration (optional):**
- `scanner_sns_topic_arn`: SNS topic ARN for S3 event notifications
- `scanner_role_arn`: IAM role ARN to grant S3 read permissions
- Both must be specified together

**Other Options:**
- `log_filter`: Filter Cloud Logging entries
- `log_prefix`: Path prefix for organizing logs in S3
- `max_batch_duration_seconds`: Maximum duration before flushing batched logs to GCS (default: `120`, range: 60-600 seconds). Trade-off: lower values = more live logs but more files, higher values = fewer files but more delay
- `force_destroy_buckets`: Allow deleting non-empty buckets (default: `false`)
- `age_threshold_minutes`: Age threshold for cleanup function (default: `30`)

**Advanced Resource Naming (optional overrides):**
- `gcs_temp_bucket_name`: Override GCS temporary bucket name
- `pubsub_topic_id`: Override Pub/Sub topic name
- `pubsub_subscription_id`: Override Pub/Sub subscription name
- `logging_sink_id`: Override Cloud Logging sink name
- `service_account_id`: Override service account name
- `transfer_function_name`: Override transfer function name
- `cleanup_function_name`: Override cleanup function name
- `scheduler_job_name`: Override scheduler job name
- `aws_role_name`: Override AWS IAM role name

Note: The function source bucket is shared across all pipelines and managed by the `shared_gcp_resources` module.

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Review Plan

```bash
terraform plan
```

### 5. Deploy Infrastructure

```bash
terraform apply
```

## Project Structure

```
.
├── main.tf                            # Root configuration with module instances
├── variables.tf                       # Root-level variables
├── terraform.tfvars                   # Your configuration (gitignored)
├── terraform.tfvars.example           # Example configuration
└── modules/
    ├── shared-gcp-resources/          # Shared GCP resources (one per project)
    │   ├── main.tf                    # API enablements, source bucket, code uploads
    │   ├── variables.tf               # Module variables
    │   ├── outputs.tf                 # Module outputs
    │   └── function_source/           # Cloud Function code (shared across pipelines)
    │       ├── transfer_function.py
    │       ├── cleanup_function.py
    │       ├── shared.py
    │       └── requirements.txt
    └── gcp-to-s3-pipeline/            # Reusable pipeline module (one per log type)
        ├── main.tf                    # Per-pipeline resources
        ├── variables.tf               # Module variables
        └── outputs.tf                 # Module outputs
```

## Usage

Once deployed, the pipeline works automatically:

1. **Logs are generated** in your GCP project
2. **Cloud Logging sink** routes matching logs to Pub/Sub topic (configurable via `log_filter` variable)
3. **Push subscription** batches log entries and writes to GCS (default: every 2 minutes or 10MB, configurable via `max_batch_duration_seconds`)
4. **Primary function** transfers batched files from GCS to S3 and deletes from GCS
5. **Cleanup function** retries any stale files (>1 hour old) every 30 minutes

Expected latency: **2-3 minutes** from log generation to S3 availability (with default 2-minute batching interval).

## Testing

After deployment, test the end-to-end pipeline with actual log entries:

### 1. Write Test Log Entries

```bash
# Write multiple test log entries (batching is more realistic)
for i in {1..5}; do
  gcloud logging write test-log-pipeline \
    "Test log entry $i at $(date)" \
    --severity=INFO
done
```

### 2. Wait for Pipeline Processing

Logs are batched and transferred within 2-3 minutes. Wait at least 3 minutes before checking.

### 3. Verify Logs Arrived in S3

```bash
# List recent files in S3 (should see files timestamped within last few minutes)
aws s3 ls s3://[S3_BUCKET_NAME]/ --recursive --human-readable

# Download and inspect a log file
aws s3 cp s3://[S3_BUCKET_NAME]/[FILENAME] - | gunzip | jq '.'
```

### 4. Monitor the Pipeline

```bash
# Check Cloud Function logs for transfer activity
gcloud functions logs read [FUNCTION_NAME] --region=[REGION] --limit=20

# View Pub/Sub subscription metrics
gcloud pubsub subscriptions describe [SUBSCRIPTION_NAME]

# Check GCS bucket (should be empty or contain only very recent files)
gsutil ls gs://[GCS_BUCKET_NAME]/
```

### Expected Behavior

- Log entries are batched together (you should see fewer files than individual logs)
- Files in S3 are gzipped (`.gz` extension or compressed content)
- GCS bucket is empty or contains only recent files (files deleted after successful transfer)
- Total latency from `gcloud logging write` to S3 availability: 2-3 minutes (with default settings)

### Batching Behavior Notes

Batching behavior varies by log volume:

- **Low volume projects**: Expect ~16 small objects per flush period (default 2 minutes, configurable via `max_batch_duration_seconds`), typically 2-15KB each. This is micro-batching behavior.
- **High volume projects**: Objects will be larger as more logs accumulate before the time/size thresholds are met, resulting in better batching efficiency.
- **Why this happens (conjecture)**: Pub/Sub likely distributes incoming messages across multiple internal workers/shards. Each shard may maintain its own batch window and flush independently when the `max_duration` or `max_bytes` (10MB) threshold is reached. With low log volume, shards timeout before accumulating significant data.

## Monitoring

### Cloud Function Logs
```bash
gcloud functions logs read [FUNCTION_NAME] --region=[REGION] --limit=50
```

### Pub/Sub Metrics
```bash
gcloud pubsub topics list-subscriptions [TOPIC_NAME]
```

### S3 Bucket Contents
```bash
aws s3 ls s3://[S3_BUCKET_NAME]/ --recursive
```

## Outputs

After successful deployment, each module provides outputs including:
- `temp_bucket_name`: GCS temporary batching bucket name
- `s3_bucket_name`: Target S3 bucket name
- `transfer_function_name`: Transfer function name
- `cleanup_function_name`: Cleanup function name
- `pubsub_topic_name`: Pub/Sub topic name
- `log_sink_name`: Cloud Logging sink name
- `aws_role_arn`: AWS IAM role ARN
- `service_account_email`: Service account email
- `test_instructions`: Quick testing commands and verification steps

See `modules/gcp-to-s3-pipeline/outputs.tf` for the complete list.

## Cleanup

To remove all resources:

```bash
terraform destroy
```

**Note**: By default, S3 buckets are configured with `force_destroy = false` to prevent accidental data loss in production. If you need to destroy non-empty buckets during testing/development, set `force_destroy_buckets = true` in your `terraform.tfvars`.

## Cost Considerations

- **GCP**: Cloud Function invocations, GCS storage and operations, Pub/Sub messages
- **AWS**: S3 storage and API requests
- **Network**: Egress charges from GCP to AWS
