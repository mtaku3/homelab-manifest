#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo >&2 "Usage: $0 <dir-to-build> [namespace]"
  exit 1
fi

DIR_TO_BUILD="$1"

if [ "$#" -eq 2 ]; then
  NAMESPACE="$2"
else
  BASENAME=$(basename "$DIR_TO_BUILD")
  NAMESPACE="$BASENAME"
fi

kustomize build "$DIR_TO_BUILD" --enable-helm \
  | yq ".metadata.namespace = (.metadata.namespace // \"$NAMESPACE\")"
