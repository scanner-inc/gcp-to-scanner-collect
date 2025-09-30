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
- **Workload Identity Federation**: Uses OIDC/JWT tokens from GCP metadata server to assume AWS role
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

Create a `terraform.tfvars` file:

```hcl
project_id     = "your-gcp-project-id"
aws_account_id = "123456789012"
region         = "us-central1"  # Optional: GCP region (default: us-central1)
aws_region     = "us-east-1"    # Optional: AWS region (default: us-east-1)
```

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

1. **Upload a file to the GCS source bucket**:
   ```bash
   gsutil cp your-file.txt gs://[GCS_BUCKET_NAME]/
   ```

2. **The pipeline automatically**:
   - Detects the new object via bucket notifications
   - Triggers the Cloud Function through Pub/Sub
   - Downloads the object from GCS
   - Uploads it to the S3 target bucket

3. **Verify the transfer**:
   ```bash
   aws s3 ls s3://[S3_BUCKET_NAME]/
   ```

## Testing

After deployment, Terraform outputs test instructions. Example:

```bash
# Upload test file
echo "test content" > test.txt
gsutil cp test.txt gs://[GCS_BUCKET_NAME]/

# Check function logs
gcloud functions logs read [FUNCTION_NAME] --region=[REGION]

# Verify in S3
aws s3 ls s3://[S3_BUCKET_NAME]/
```

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

## Configuration Details

### Function Specifications
- **Runtime**: Python 3.11
- **Memory**: 512 MB
- **Timeout**: 540 seconds (9 minutes)
- **Max Instances**: 10
- **Min Instances**: 0 (scales to zero)
- **Streaming**: Files are streamed directly from GCS to S3 (not loaded into memory)
- **Retry Policy**: Automatic retries enabled for failed transfers

### Security Features
- Service accounts with minimal required permissions
- Workload Identity Federation for cross-cloud authentication
- S3 bucket encryption (AES256)
- S3 versioning enabled
- No hardcoded credentials

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

## Troubleshooting

### Function Not Triggering
- Check Pub/Sub topic has proper permissions
- Verify bucket notifications are configured
- Review function logs for errors

### Authentication Errors
- Ensure Workload Identity Pool is properly configured
- Verify AWS IAM role trust policy
- Check service account permissions

### Transfer Failures
- Verify network connectivity
- Check object size (function has 9-minute timeout)
- Review function memory allocation for large files

## Cost Considerations

- **GCP**: Cloud Function invocations, GCS storage and operations, Pub/Sub messages
- **AWS**: S3 storage and API requests
- **Network**: Egress charges from GCP to AWS
