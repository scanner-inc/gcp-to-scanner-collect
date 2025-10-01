"""
Shared utilities for GCS to S3 transfer functions
"""
import os
import zlib
import boto3
import urllib.request
import google.auth
from google.auth.transport.requests import AuthorizedSession
from google.cloud import storage

# Initialize GCS client
gcs_client = storage.Client()

# Get credentials for raw HTTP access
credentials, project = google.auth.default()
authed_session = AuthorizedSession(credentials)


class GzipStreamWrapper:
    """Wraps a file-like object to compress data on-the-fly using gzip"""
    def __init__(self, fileobj, chunk_size=65536):
        self.fileobj = fileobj
        self.chunk_size = chunk_size
        # wbits=16+15 creates a gzip-compatible compressor
        # 15 is max window bits, +16 adds gzip header/trailer
        self.compressor = zlib.compressobj(wbits=16 + zlib.MAX_WBITS)
        self.buffer = b''
        self.finished = False

    def read(self, size=-1):
        """Read and compress data in chunks"""
        while len(self.buffer) < size or size == -1:
            if self.finished:
                break

            # Read a chunk from source
            chunk = self.fileobj.read(self.chunk_size)

            if not chunk:
                # No more data, finalize compression
                self.buffer += self.compressor.flush()
                self.finished = True
                break

            # Compress the chunk
            self.buffer += self.compressor.compress(chunk)

            # If we have enough data and size is specified, break
            if size != -1 and len(self.buffer) >= size:
                break

        # Return requested amount of data
        if size == -1:
            result = self.buffer
            self.buffer = b''
        else:
            result = self.buffer[:size]
            self.buffer = self.buffer[size:]

        return result


def get_gcp_identity_token(audience):
    """Get GCP identity token (JWT) from metadata service"""
    metadata_server_url = (
        "http://metadata.google.internal/computeMetadata/v1/instance"
        f"/service-accounts/default/identity?audience={audience}"
    )

    req = urllib.request.Request(metadata_server_url)
    req.add_header("Metadata-Flavor", "Google")

    try:
        response = urllib.request.urlopen(req)
        return response.read().decode('utf-8')
    except Exception as e:
        print(f"Error getting identity token from metadata service: {e}")
        raise


def get_aws_credentials():
    """Get AWS credentials using OIDC JWT from metadata server"""
    role_arn = os.environ['AWS_ROLE_ARN']

    # Get ID token (JWT) from GCP metadata service with role ARN as audience
    id_token = get_gcp_identity_token(role_arn)

    # Create STS client and assume role with web identity
    sts_client = boto3.client('sts', region_name=os.environ['AWS_REGION'])

    response = sts_client.assume_role_with_web_identity(
        RoleArn=role_arn,
        RoleSessionName='gcp-logging-to-s3-session',
        WebIdentityToken=id_token,
        DurationSeconds=3600
    )

    return response['Credentials']


def check_s3_object_exists(s3_client, bucket, key):
    """Check if an object already exists in S3"""
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except s3_client.exceptions.ClientError as e:
        if e.response['Error']['Code'] == '404':
            return False
        raise


class RawGCSStream:
    """
    Wraps raw HTTP streaming from GCS to get gzip-encoded content.
    Uses response.raw to bypass requests library's automatic decompression.
    """
    def __init__(self, bucket_name, object_name):
        self.url = f'https://storage.googleapis.com/{bucket_name}/{object_name}'
        # Request with gzip encoding - GCS will send content-encoding:gzip for pre-gzipped files
        self.response = authed_session.get(
            self.url,
            stream=True,
            headers={'Accept-Encoding': 'gzip'}
        )
        self.response.raise_for_status()

        # Use response.raw to bypass requests' automatic decompression
        # This gives us the raw bytes from urllib3, preserving gzip encoding
        self.raw = self.response.raw
        self.buffer = b''
        self.finished = False

    def read(self, size=-1):
        """Read raw bytes from GCS without decompression"""
        try:
            if size == -1:
                # Read all remaining data
                result = self.buffer + self.raw.read()
                self.buffer = b''
                self.finished = True
                return result

            # Read in chunks until we have enough data
            while len(self.buffer) < size and not self.finished:
                chunk = self.raw.read(65536)
                if not chunk:
                    self.finished = True
                    break
                self.buffer += chunk

            # Return requested amount
            result = self.buffer[:size]
            self.buffer = self.buffer[size:]
            return result

        except Exception as e:
            print(f"Error reading from GCS: {e}")
            return b''

    def close(self):
        """Close the HTTP response"""
        self.response.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()


def transfer_blob_to_s3(blob, s3_client, target_bucket, transferred_by='unknown'):
    """
    Core transfer logic: stream from GCS to S3 with compression handling
    Returns True if successful (transferred or already exists), False on error
    """
    try:
        object_name = blob.name

        # Check if object already exists in S3
        # Note: HeadObject returns 404 during uploads, so we won't delete prematurely
        if check_s3_object_exists(s3_client, target_bucket, object_name):
            print(f"  Object already exists in S3: {object_name}, deleting from GCS")
            blob.delete()
            return True

        # Determine content type based on file extension
        if object_name.endswith('.jsonl') or object_name.endswith('.ndjson'):
            content_type = 'application/x-ndjson'
        else:
            # Fall back to blob's content type or default to octet-stream
            content_type = blob.content_type or 'application/octet-stream'

        # Get content encoding
        gcs_content_encoding = blob.content_encoding
        is_gzipped = gcs_content_encoding == 'gzip' if gcs_content_encoding else False

        print(f"  GCS content-encoding: {gcs_content_encoding}, size: {blob.size} bytes")

        # If already gzipped in GCS, try to stream the raw compressed bytes
        if is_gzipped:
            print(f"  Streaming gzipped file from GCS (requesting gzip encoding)")
            with RawGCSStream(blob.bucket.name, blob.name) as gcs_stream:
                s3_client.upload_fileobj(
                    gcs_stream,
                    target_bucket,
                    object_name,
                    ExtraArgs={
                        'ContentEncoding': 'gzip',
                        'ContentType': content_type,
                        'Metadata': {
                            'source-bucket': blob.bucket.name,
                            'source-size': str(blob.size),
                            'original-encoding': 'gzip',
                            'transferred-by': transferred_by
                        }
                    }
                )
        else:
            # Stream and compress on-the-fly using zlib
            # Use blob.open() to let GCS handle any other content encodings transparently
            print(f"  Streaming and compressing {blob.size} bytes on-the-fly")
            with blob.open('rb') as gcs_stream:
                # Wrap the stream with our gzip compressor
                compressed_stream = GzipStreamWrapper(gcs_stream)

                s3_client.upload_fileobj(
                    compressed_stream,
                    target_bucket,
                    object_name,
                    ExtraArgs={
                        'ContentEncoding': 'gzip',
                        'ContentType': content_type,
                        'Metadata': {
                            'source-bucket': blob.bucket.name,
                            'source-size': str(blob.size),
                            'original-encoding': gcs_content_encoding or 'none',
                            'transferred-by': transferred_by
                        }
                    }
                )

        print(f"  Successfully uploaded to S3: s3://{target_bucket}/{object_name}")

        # Delete from GCS after successful upload
        # Safe to delete because S3 PutObject/upload_fileobj only makes object visible
        # after the upload is complete
        blob.delete()
        print(f"  Deleted from GCS: gs://{blob.bucket.name}/{object_name}")

        return True

    except Exception as e:
        print(f"  Error transferring {blob.name}: {str(e)}")
        return False