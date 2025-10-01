"""
Unit tests for shared.py utilities
Run with: python -m pytest test_shared.py -v
Or: python test_shared.py

Note: Only tests GzipStreamWrapper (doesn't require GCP/AWS dependencies)

What this validates:
- GzipStreamWrapper produces valid gzip-compressed output
- Output is compatible with standard gzip decompression tools
- Streaming compression works correctly (no need to load entire file in memory)
- Works with various data types (text, binary, empty, large files)
- Handles chunked reading correctly
- Compression actually reduces size for repetitive data
"""
import io
import gzip
import sys

# Import the actual implementation from shared.py
# The GCS/S3 client imports in shared.py won't cause issues since we're only importing the class
from shared import GzipStreamWrapper


def test_gzip_stream_wrapper_basic():
    """Test that GzipStreamWrapper produces valid gzip output"""
    # Create some test data
    original_data = b"Hello, World! " * 100

    # Wrap it in a file-like object
    source = io.BytesIO(original_data)

    # Compress using our wrapper
    wrapper = GzipStreamWrapper(source)
    compressed_data = wrapper.read()

    # Verify it's actually compressed (should be smaller for repetitive data)
    assert len(compressed_data) < len(original_data), "Data should be compressed"

    # Verify it's valid gzip by decompressing
    decompressed = gzip.decompress(compressed_data)
    assert decompressed == original_data, "Decompressed data should match original"

    print(f"✓ Basic compression: {len(original_data)} bytes → {len(compressed_data)} bytes")


def test_gzip_stream_wrapper_chunked_reading():
    """Test that reading in chunks produces the same result"""
    original_data = b"The quick brown fox jumps over the lazy dog. " * 50

    # Compress by reading all at once
    source1 = io.BytesIO(original_data)
    wrapper1 = GzipStreamWrapper(source1)
    compressed_all = wrapper1.read()

    # Compress by reading in chunks
    source2 = io.BytesIO(original_data)
    wrapper2 = GzipStreamWrapper(source2)
    compressed_chunks = b''
    while True:
        chunk = wrapper2.read(1024)  # Read 1KB at a time
        if not chunk:
            break
        compressed_chunks += chunk

    # Both methods should produce valid gzip
    decompressed_all = gzip.decompress(compressed_all)
    decompressed_chunks = gzip.decompress(compressed_chunks)

    assert decompressed_all == original_data
    assert decompressed_chunks == original_data

    print(f"✓ Chunked reading: both methods decompress correctly")


def test_gzip_stream_wrapper_empty_input():
    """Test handling of empty input"""
    source = io.BytesIO(b"")
    wrapper = GzipStreamWrapper(source)
    compressed = wrapper.read()

    # Even empty input should produce valid gzip (just header/trailer)
    decompressed = gzip.decompress(compressed)
    assert decompressed == b""
    assert len(compressed) > 0, "Empty gzip still has header/trailer"

    print(f"✓ Empty input: {len(compressed)} bytes of gzip overhead")


def test_gzip_stream_wrapper_large_data():
    """Test with larger data to ensure streaming works"""
    # Create 1MB of data
    original_data = b"x" * (1024 * 1024)

    source = io.BytesIO(original_data)
    wrapper = GzipStreamWrapper(source, chunk_size=8192)
    compressed = wrapper.read()

    # This should compress very well (all same byte)
    assert len(compressed) < len(original_data) * 0.01, "Repetitive data should compress >99%"

    # Verify correctness
    decompressed = gzip.decompress(compressed)
    assert decompressed == original_data

    print(f"✓ Large data (1MB): {len(original_data)} bytes → {len(compressed)} bytes ({len(compressed)*100/len(original_data):.2f}%)")


def test_gzip_compatibility_with_gunzip():
    """Test that output is compatible with standard gzip tools"""
    original_data = b"This is a test of gzip compatibility.\n" * 10

    source = io.BytesIO(original_data)
    wrapper = GzipStreamWrapper(source)
    compressed = wrapper.read()

    # Test with gzip.GzipFile (another standard way to decompress)
    decompressed = gzip.GzipFile(fileobj=io.BytesIO(compressed)).read()
    assert decompressed == original_data

    # Test with gzip module's open
    with gzip.open(io.BytesIO(compressed), 'rb') as f:
        decompressed2 = f.read()
    assert decompressed2 == original_data

    print(f"✓ Compatibility: works with gzip.GzipFile and gzip.open")


def test_gzip_stream_wrapper_binary_data():
    """Test with binary data (not just text)"""
    # Create binary data with various byte values
    original_data = bytes(range(256)) * 100

    source = io.BytesIO(original_data)
    wrapper = GzipStreamWrapper(source)
    compressed = wrapper.read()

    decompressed = gzip.decompress(compressed)
    assert decompressed == original_data

    print(f"✓ Binary data: {len(original_data)} bytes → {len(compressed)} bytes")


def test_gzip_stream_wrapper_multiple_reads():
    """Test that wrapper can handle multiple read() calls correctly"""
    original_data = b"A" * 1000

    source = io.BytesIO(original_data)
    wrapper = GzipStreamWrapper(source, chunk_size=100)

    # Read in multiple small chunks
    chunks = []
    for _ in range(5):
        chunk = wrapper.read(50)
        if chunk:
            chunks.append(chunk)

    # Read the rest
    rest = wrapper.read()
    if rest:
        chunks.append(rest)

    # Combine and decompress
    compressed = b''.join(chunks)
    decompressed = gzip.decompress(compressed)
    assert decompressed == original_data

    print(f"✓ Multiple reads: {len(chunks)} chunks, decompresses correctly")


def run_all_tests():
    """Run all tests and report results"""
    print("Running GzipStreamWrapper tests...\n")

    tests = [
        test_gzip_stream_wrapper_basic,
        test_gzip_stream_wrapper_chunked_reading,
        test_gzip_stream_wrapper_empty_input,
        test_gzip_stream_wrapper_large_data,
        test_gzip_compatibility_with_gunzip,
        test_gzip_stream_wrapper_binary_data,
        test_gzip_stream_wrapper_multiple_reads,
    ]

    passed = 0
    failed = 0

    for test in tests:
        try:
            test()
            passed += 1
        except AssertionError as e:
            print(f"✗ {test.__name__}: {e}")
            failed += 1
        except Exception as e:
            print(f"✗ {test.__name__}: Unexpected error: {e}")
            failed += 1

    print(f"\n{'='*60}")
    print(f"Results: {passed} passed, {failed} failed")
    print(f"{'='*60}")

    return failed == 0


if __name__ == "__main__":
    import sys
    success = run_all_tests()
    sys.exit(0 if success else 1)