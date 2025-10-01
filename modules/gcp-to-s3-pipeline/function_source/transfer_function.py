"""
Primary transfer function: GCS -> S3 with compression handling
Triggered on GCS object creation in the temporary batching bucket.
"""
import os
import functions_framework
from shared import gcs_client, get_aws_credentials, transfer_blob_to_s3
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

    print(f"Processing: gs://{bucket_name}/{object_name}")

    try:
        # Get blob reference
        bucket = gcs_client.bucket(bucket_name)
        blob = bucket.blob(object_name)

        # Reload to get current metadata
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

        # Use shared transfer logic
        if transfer_blob_to_s3(blob, s3_client, target_bucket, transferred_by='transfer-function'):
            print(f"Successfully processed: {object_name}")
        else:
            print(f"Failed to process: {object_name}")

    except Exception as e:
        print(f"Error processing file: {str(e)}")
        # Don't raise - we don't want retries on this function
        # The cleanup function will retry stale files instead