"""
Mirror function: copies objects from a monitored (customer-owned) GCS bucket to S3.

Receives GCS OBJECT_FINALIZE notifications via a Pub/Sub push subscription.
Applies configurable key path filtering (KEY_PREFIXES / KEY_INCLUDE_REGEX /
KEY_EXCLUDE_REGEX) and copies matching objects to S3. Never deletes from the
source bucket.

Reliability contract: this function ACKS (204) anything that retrying cannot
fix (filtered keys, deleted objects, malformed messages) and NACKS (500)
transient failures so Pub/Sub redelivers with exponential backoff; after
max_delivery_attempts the message lands in the dead-letter topic, where a
monitoring alert fires.
"""
import base64
import json
import os

import functions_framework
from google.api_core.exceptions import NotFound

from shared import (
    gcs_client,
    get_aws_credentials,
    transfer_blob_to_s3,
    key_passes_filter,
    build_dest_key,
    log_structured,
)
import boto3

ACK = ("", 204)


def _nack(reason, **fields):
    """Log and return 500 so Pub/Sub redelivers the message with backoff."""
    log_structured(reason, severity='ERROR', **fields)
    return (reason, 500)


@functions_framework.http
def mirror_to_s3(request):
    """
    HTTP function receiving Pub/Sub push messages for GCS object finalize
    events. Filters on the object key path, then copies matching objects to
    S3 (leaving the source object in place).
    """

    # Parse the Pub/Sub push envelope
    envelope = request.get_json(silent=True)
    message = envelope.get('message') if isinstance(envelope, dict) else None
    if not isinstance(message, dict):
        log_structured(
            "Ignored: request is not a Pub/Sub push envelope",
            severity='ERROR',
            body_prefix=str(envelope)[:200]
        )
        return ACK  # malformed forever - retrying cannot fix

    attributes = message.get('attributes') or {}
    event_type = attributes.get('eventType')
    bucket_name = attributes.get('bucketId')
    object_name = attributes.get('objectId')

    # Fall back to the JSON_API_V1 payload if attributes are missing
    if (not bucket_name or not object_name) and message.get('data'):
        try:
            payload = json.loads(base64.b64decode(message['data']))
            bucket_name = bucket_name or payload.get('bucket')
            object_name = object_name or payload.get('name')
        except (ValueError, KeyError, TypeError):
            # covers binascii.Error (a ValueError), bad JSON, and non-string
            # data; the missing-identifiers check below acks these
            pass

    if not bucket_name or not object_name:
        log_structured(
            "Ignored: notification missing bucket/object identifiers",
            severity='ERROR',
            attributes=attributes
        )
        return ACK

    # The notification config only sends OBJECT_FINALIZE, but be defensive
    if event_type and event_type != 'OBJECT_FINALIZE':
        log_structured("Ignored: unexpected event type", eventType=event_type, object=object_name)
        return ACK

    # Only process files from the monitored source bucket
    expected_bucket = os.environ.get('SOURCE_BUCKET')
    if bucket_name != expected_bucket:
        log_structured(
            "Rejected: unexpected bucket",
            severity='WARNING',
            bucket=bucket_name,
            expected=expected_bucket,
            object=object_name
        )
        return ACK

    # Apply key path filtering (prefix filtering also happens server-side via
    # the notification config's object_name_prefix; regexes only apply here)
    if not key_passes_filter(object_name):
        log_structured(
            "Skipped: object key filtered out",
            object=object_name,
            bucket=bucket_name
        )
        return ACK

    try:
        # Get blob reference
        bucket = gcs_client.bucket(bucket_name)
        blob = bucket.blob(object_name)
        try:
            blob.reload()
        except NotFound:
            log_structured(
                "Skipped: object no longer exists in source bucket",
                object=object_name,
                bucket=bucket_name
            )
            return ACK  # deleted before we got to it - retrying cannot fix

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

        # Copy to S3 (do not delete the source object)
        result = transfer_blob_to_s3(
            blob,
            s3_client,
            target_bucket,
            transferred_by='mirror-function',
            dest_key=build_dest_key(object_name),
            delete_source=False
        )

        if result is None:
            # transfer_blob_to_s3 logged the underlying error
            return _nack("Transfer to S3 failed - message will be retried", object=object_name)

        if result['status'] == 'already_exists':
            log_structured(
                "Already in S3",
                object=result['object']
            )
        else:
            log_structured(
                "Mirrored to S3",
                object=result['object'],
                gzip_input=result['gzip_input'],
                input_size=result['input_size'],
                output_size=result['output_size'],
                source_bucket=f"gs://{result['source_bucket']}",
                target_bucket=f"s3://{result['target_bucket']}"
            )
        return ACK

    except Exception as e:
        return _nack(
            "Error in mirror function - message will be retried",
            error=str(e),
            object=object_name
        )
