# GCP Logging to S3 Pipeline

Automated pipeline that exports GCP Cloud Logging logs to Amazon S3 with 1-3 minute latency. Logs are batched in GCS temporarily, then transferred to S3 with efficient compression handling.

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

## Prerequisites

- Terraform >= 1.0
- Google Cloud SDK (`gcloud`)
- AWS CLI (`aws`)
- Active GCP project with billing enabled
- AWS account with appropriate permissions
- Configured credentials for both clouds

## Setup

### 1. Configure Variables

Create a `terraform.tfvars` file.

Copy `terraform.tfvars.example` to `terraform.tfvars` and modify.

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
3. **Push subscription** batches log entries and writes to GCS (every 1 minute or 10MB of logs)
4. **Primary function** transfers batched files from GCS to S3 and deletes from GCS
5. **Cleanup function** retries any stale files (>1 hour old) every 30 minutes

Expected latency: **1-3 minutes** from log generation to S3 availability.

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

Logs are batched and transferred within 1-3 minutes. Wait at least 2 minutes before checking.

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
- Total latency from `gcloud logging write` to S3 availability: 1-3 minutes

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

**Note**: Buckets are configured with `force_destroy = true` for easy cleanup. In production, you may want to change this.

## Cost Considerations

- **GCP**: Cloud Function invocations, GCS storage and operations, Pub/Sub messages
- **AWS**: S3 storage and API requests
- **Network**: Egress charges from GCP to AWS
