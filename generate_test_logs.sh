#!/bin/bash

# Script to generate test logs for GCP Cloud Logging
# Runs 10 parallel processes, each writing 100 logs (~1KB each)
# This increases volume to verify batch sizing works more like we expected

NUM_PROCESSES=10
LOGS_PER_PROCESS=100
LOG_NAME="test-log-pipeline"

# Function to generate a single ~1KB log entry
generate_log() {
  local process_id=$1
  local log_num=$2

  # Create ~1KB of random data (base64 encoded random bytes)
  local payload=$(head -c 768 /dev/urandom | base64)

  # Write log with timestamp and payload
  gcloud logging write "$LOG_NAME" \
    "Process $process_id - Log $log_num - Timestamp: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) - Payload: $payload" \
    --severity=INFO
}

# Function to run in each parallel process
worker() {
  local worker_id=$1
  echo "Worker $worker_id starting..."

  for i in $(seq 1 $LOGS_PER_PROCESS); do
    generate_log $worker_id $i

    # Show progress every 10 logs
    if [ $((i % 10)) -eq 0 ]; then
      echo "Worker $worker_id: $i/$LOGS_PER_PROCESS logs sent"
    fi
  done

  echo "Worker $worker_id completed $LOGS_PER_PROCESS logs"
}

echo "Starting log generation: $NUM_PROCESSES processes x $LOGS_PER_PROCESS logs each"
echo "Total logs to generate: $((NUM_PROCESSES * LOGS_PER_PROCESS))"
echo "Log name: $LOG_NAME"
echo ""

# Start all worker processes in parallel
for i in $(seq 1 $NUM_PROCESSES); do
  worker $i &
done

# Wait for all background processes to complete
wait

echo ""
echo "All logs generated successfully!"
echo "Check logs with: gcloud logging read 'logName=\"projects/\$(gcloud config get-value project)/logs/$LOG_NAME\"' --limit=20 --format=json"
