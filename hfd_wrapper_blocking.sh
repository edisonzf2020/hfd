#!/usr/bin/env bash

# Do not use `set -e`: retry logic requires manual error handling
# Enable pipefail to correctly detect failures in pipelines
set -o pipefail


# ----------------------
# Argument check
# ----------------------
if [ $# -ne 1 ]; then
  echo "Usage: $0 <org_name/repo_name>"
  exit 1
fi

REPO="$1"
ORG_NAME="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

# ----------------------
# Base paths
# ----------------------
BASE_MODEL_DIR="$HOME/data/models/shared"
BASE_LOG_DIR="$HOME/playground/hfd/logs"

LOCAL_DIR="$BASE_MODEL_DIR/$ORG_NAME/$REPO_NAME"
LOG_DIR="$BASE_LOG_DIR/$ORG_NAME"
LOG_FILE="$LOG_DIR/hfd_${REPO_NAME}.log"

mkdir -p "$LOCAL_DIR"
mkdir -p "$LOG_DIR"

# ----------------------
# Retry config
# ----------------------
MAX_RETRIES=3
SLEEP_BASE=30

echo "Downloading $REPO"
echo "Local dir: $LOCAL_DIR"
echo "Log file : $LOG_FILE"

attempt=1
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  echo "Attempt $attempt / $MAX_RETRIES"
  echo "Start time: $(date)"

  nohup ./hfd.sh "$REPO" \
    --local-dir "$LOCAL_DIR" \
    > "$LOG_FILE" 2>&1

  rc=$?

  if [ "$rc" -eq 0 ]; then
    echo "Download succeeded: $REPO"
    echo "End time: $(date)"
    exit 0
  fi

  echo "Download failed (exit code=$rc)"
  echo "Attempt $attempt failed at $(date)"

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    sleep_time=$((SLEEP_BASE * attempt))
    echo "Retrying after ${sleep_time}s..."
    sleep "$sleep_time"
  fi

  attempt=$((attempt + 1))
done

echo "Download permanently failed after $MAX_RETRIES attempts: $REPO"
exit 1
