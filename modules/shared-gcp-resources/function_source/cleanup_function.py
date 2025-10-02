"""
Cleanup function: Retries stale files in GCS bucket
Triggered by Cloud Scheduler every 30 minutes.
Looks for files older than 1 hour and attempts to transfer them.
"""
import os
from datetime import datetime, timezone, timedelta
import functions_framework
from shared import gcs_client, get_aws_credentials, transfer_blob_to_s3, log_structured
import boto3


@functions_framework.http
def cleanup_stale_files(request):
    """
    HTTP function triggered by Cloud Scheduler every 30 minutes.
    Finds files older than 1 hour in the temporary GCS bucket and retries transfer.
    """

    try:
        # Get environment variables
        temp_bucket_name = os.environ['TEMP_BUCKET']
        target_bucket = os.environ['TARGET_BUCKET']
        age_threshold_minutes = int(os.environ.get('AGE_THRESHOLD_MINUTES', '60'))

        # Calculate cutoff time
        cutoff_time = datetime.now(timezone.utc) - timedelta(minutes=age_threshold_minutes)

        # Get AWS credentials via OIDC
        aws_creds = get_aws_credentials()

        # Create S3 client with temporary credentials
        s3_client = boto3.client(
            's3',
            region_name=os.environ['AWS_REGION'],
            aws_access_key_id=aws_creds['AccessKeyId'],
            aws_secret_access_key=aws_creds['SecretAccessKey'],
            aws_session_token=aws_creds['SessionToken']
        )

        # Iterate through blobs in the temporary bucket
        bucket = gcs_client.bucket(temp_bucket_name)

        success_count = 0
        failure_count = 0
        total_files = 0
        stale_files = 0

        # Iterate over blobs - memory-efficient as it paginates automatically
        for blob in bucket.list_blobs():
            total_files += 1

            # Check if blob is older than threshold
            if blob.time_created < cutoff_time:
                stale_files += 1
                result = transfer_blob_to_s3(blob, s3_client, target_bucket, transferred_by='cleanup-function')
                if result:
                    success_count += 1
                else:
                    failure_count += 1

        # Log summary
        log_structured(
            "Cleanup complete",
            total_files=total_files,
            stale_files=stale_files,
            success=success_count,
            failures=failure_count,
            age_threshold_minutes=age_threshold_minutes
        )

        result = {
            'total_files': total_files,
            'stale_files': stale_files,
            'success': success_count,
            'failures': failure_count,
            'cutoff_time': cutoff_time.isoformat()
        }

        return result, 200

    except Exception as e:
        log_structured(
            "Cleanup function failed",
            severity='ERROR',
            error=str(e)
        )
        return {'error': str(e)}, 500