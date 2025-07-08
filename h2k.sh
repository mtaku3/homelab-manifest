#!/usr/bin/env bash

set -e

if [ $# -lt 1 ]; then
  echo "Usage: $0 TARGET_DIRECTORY"
  exit 1
fi

TARGET="$1"

if [ ! -d "$TARGET" ]; then
  echo "Error: '$TARGET' is not a directory."
  exit 1
fi

find "$TARGET" -type f | while read -r filepath; do
  relpath="${filepath#$TARGET/}"
  newrelpath=$(echo "$relpath" | sed 's#/charts/#/#g; s#/templates/#/#g; s#^charts/##; s#^templates/##; s#/charts$##; s#/templates$##')
  newpath="$TARGET/$newrelpath"
  mkdir -p "$(dirname "$newpath")"
  mv "$filepath" "$newpath"
done

find "$TARGET" -type d -empty -delete

cd "$TARGET"
kustomize create --autodetect --recursive

