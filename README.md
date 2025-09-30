# GCP Logging to S3 Pipeline

Automated pipeline that exports GCP Cloud Logging logs to Amazon S3 with 2-3 minute latency. Logs are batched in GCS temporarily, then transferred to S3 with efficient compression handling.

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

### 1. Configure Variables

Copy `terraform.tfvars.example` to `terraform.tfvars` and modify:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your configuration
```

#### Key Configuration Options

**Required:**
- `project_id`: Your GCP project ID
- `aws_account_id`: Your AWS account ID

**S3 Bucket Options (choose one):**
- `s3_bucket_name`: Create a new bucket with a custom name (e.g., `"mycompany-gcp-audit-logs"`)
- `existing_s3_bucket_name`: Use an existing S3 bucket (must also set `log_prefix`)
- Neither: Auto-generates bucket name as `logging-s3-target-{account_id}-{random_suffix}`

**Scanner Integration (optional):**
- `scanner_sns_topic_arn`: SNS topic ARN for S3 event notifications
- `scanner_role_arn`: IAM role ARN to grant S3 read permissions
- Both must be specified together to enable scanner integration

**Other Options:**
- `log_filter`: Filter Cloud Logging entries (empty = all logs, or specify filters for audit logs, specific services, etc.)
- `log_prefix`: Path prefix for organizing logs in S3 (default: `"logs"`)
- `force_destroy_buckets`: Set to `true` for testing/dev to allow deleting non-empty buckets (default: `false` for production safety)

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Review Plan

```bash
terraform plan
```

### 4. Deploy Infrastructure

```bash
terraform apply
```

## Usage

Once deployed, the pipeline works automatically:

1. **Logs are generated** in your GCP project
2. **Cloud Logging sink** routes matching logs to Pub/Sub topic (configurable via `log_filter` variable)
3. **Push subscription** batches log entries and writes to GCS (every 2 minutes or 10MB of logs)
4. **Primary function** transfers batched files from GCS to S3 and deletes from GCS
5. **Cleanup function** retries any stale files (>1 hour old) every 30 minutes

Expected latency: **2-3 minutes** from log generation to S3 availability.

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
- Total latency from `gcloud logging write` to S3 availability: 2-3 minutes

### Batching Behavior Notes

Batching behavior varies by log volume:

- **Low volume projects**: Expect ~16 small objects per flush period (2 minutes), typically 2-15KB each. This is micro-batching behavior.
- **High volume projects**: Objects will be larger as more logs accumulate before the time/size thresholds are met, resulting in better batching efficiency.
- **Why this happens (conjecture)**: Pub/Sub likely distributes incoming messages across multiple internal workers/shards. Each shard may maintain its own batch window and flush independently when the `max_duration` (2 minutes) or `max_bytes` (10MB) threshold is reached. With low log volume, shards timeout before accumulating significant data.

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

After successful deployment, Terraform provides:
- `gcs_bucket_name`: Source GCS bucket name
- `s3_bucket_name`: Target S3 bucket name
- `function_name`: Cloud Function name
- `pubsub_topic_name`: Pub/Sub topic name
- `aws_role_arn`: AWS IAM role ARN
- `test_instructions`: Quick testing commands

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
