"""
Primary transfer function: GCS -> S3 with compression handling
Triggered on GCS object creation in the temporary batching bucket.
"""
import os
import functions_framework
from shared import gcs_client, get_aws_credentials, transfer_blob_to_s3, log_structured
import boto3


@functions_framework.cloud_event
def transfer_to_s3(cloud_event):
    """
    Cloud Function triggered by GCS object creation.
    Downloads from GCS (with accept-encoding: gzip), ensures compression,
    uploads to S3 (with content-encoding: gzip), then deletes from GCS.
    """

    # Parse CloudEvent for GCS object info
    data = cloud_event.data
    bucket_name = data['bucket']
    object_name = data['name']

    # Only process files from expected temp bucket
    expected_bucket = os.environ.get('TEMP_BUCKET')
    if bucket_name != expected_bucket:
        log_structured(
            "Rejected: unexpected bucket",
            severity='WARNING',
            bucket=bucket_name,
            expected=expected_bucket,
            object=object_name
        )
        return

    try:
        # Get blob reference
        bucket = gcs_client.bucket(bucket_name)
        blob = bucket.blob(object_name)
        blob.reload()

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

        target_bucket = os.environ['TARGET_BUCKET']

        # Transfer to S3
        result = transfer_blob_to_s3(blob, s3_client, target_bucket, transferred_by='transfer-function')

        if result:
            if result['status'] == 'already_exists':
                log_structured(
                    "Already in S3",
                    object=result['object']
                )
            else:
                log_structured(
                    "Transferred to S3",
                    object=result['object'],
                    gzip_input=result['gzip_input'],
                    input_size=result['input_size'],
                    output_size=result['output_size'],
                    source_bucket=f"gs://{result['source_bucket']}",
                    target_bucket=f"s3://{result['target_bucket']}"
                )
        # Errors are logged in transfer_blob_to_s3

    except Exception as e:
        log_structured(
            "Error in transfer function",
            severity='ERROR',
            error=str(e),
            object=object_name
        )
        # Don't raise - we don't want retries on this function
        # The cleanup function will retry stale files instead
