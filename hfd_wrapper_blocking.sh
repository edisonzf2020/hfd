#!/usr/bin/env bash

set -e

# Argument check
if [ $# -ne 1 ]; then
  echo "Usage: $0 <org_name/repo_name>"
  exit 1
fi

REPO="$1"
ORG_NAME="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

# Base paths
BASE_MODEL_DIR="$HOME/data/models/shared"
BASE_LOG_DIR="$HOME/playground/hfd/logs"

# Derived paths
LOCAL_DIR="$BASE_MODEL_DIR/$ORG_NAME/$REPO_NAME"
LOG_DIR="$BASE_LOG_DIR/$ORG_NAME"
LOG_FILE="$LOG_DIR/hfd_${REPO_NAME}.log"

# Ensure directories exist
mkdir -p "$LOCAL_DIR"
mkdir -p "$LOG_DIR"

echo "Downloading $REPO"
echo "  Local dir: $LOCAL_DIR"
echo "  Log file : $LOG_FILE"

# Foreground execution (important)
./hfd.sh "$REPO" \
  --local-dir "$LOCAL_DIR" \
  > "$LOG_FILE" 2>&1

echo "Finished $REPO"
