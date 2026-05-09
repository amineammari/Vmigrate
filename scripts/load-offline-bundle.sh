#!/usr/bin/env bash
set -Eeuo pipefail

bundle_file="${1:-}"
if [[ -z "${bundle_file}" ]]; then
  echo "Usage: $0 offline/images/vm-migrator-images-<version>.tar" >&2
  exit 2
fi

docker load -i "${bundle_file}"
