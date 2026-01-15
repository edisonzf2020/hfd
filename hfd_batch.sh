#!/usr/bin/env bash

set -e

# ----------------------
# Argument check
# ----------------------
if [ $# -ne 1 ]; then
  echo "Usage: $0 <batch_list.txt>"
  exit 1
fi

BATCH_FILE="$1"

if [ ! -f "$BATCH_FILE" ]; then
  echo "Batch file not found: $BATCH_FILE"
  exit 1
fi

# ----------------------
# Process batch list
# ----------------------
while IFS= read -r REPO || [ -n "$REPO" ]; do
  # Skip empty lines and comments
  [[ -z "$REPO" || "$REPO" =~ ^# ]] && continue

  echo "========================================"
  echo "Starting download: $REPO"
  echo "Start time: $(date)"
  echo "========================================"

  ./hfd_wrapper_blocking.sh "$REPO"

  echo "----------------------------------------"
  echo "Finished download: $REPO"
  echo "End time: $(date)"
  echo "----------------------------------------"
done < "$BATCH_FILE"

echo "All downloads completed."
