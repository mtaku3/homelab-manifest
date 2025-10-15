#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <file-or-directory>"
  exit 1
fi

TARGET="$1"

process_file() {
  local file="$1"

  if grep -qE '^[[:space:]]*kind:[[:space:]]*Secret' "$file"; then
    echo "Sealing Secret in $file"

    # Try to seal, outputting errors to stderr naturally
    if sealed_output=$(cat "$file" | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets -o yaml 2>&1); then
      echo "$sealed_output" > "$file"
      echo "✅ Successfully sealed $file"
    else
      echo "❌ Failed to seal $file"
      echo "$sealed_output"
    fi
  else
    echo "Skipping $file (not a Secret)"
  fi
}

if [ -d "$TARGET" ]; then
  find "$TARGET" -type f \( -name "*.yaml" -o -name "*.yml" \) | while read -r f; do
    process_file "$f"
  done
elif [ -f "$TARGET" ]; then
  process_file "$TARGET"
else
  echo "Error: $TARGET is not a valid file or directory"
  exit 1
fi

