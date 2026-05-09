#!/usr/bin/env bash
set -Eeuo pipefail

version="${VM_MIGRATOR_VERSION:-local}"
bundle_dir="${OFFLINE_BUNDLE_DIR:-offline/images}"
bundle_file="${bundle_dir}/vm-migrator-images-${version}.tar"

mkdir -p "${bundle_dir}"

docker compose build
docker compose -f docker-compose.conversion.yml build

docker save \
  "vm-migrator/backend:${version}" \
  "vm-migrator/frontend:${version}" \
  "vm-migrator/conversion-worker:${version}" \
  "mariadb:10.11.8" \
  "redis:7.2.5-alpine" \
  "nginx:1.27.3-alpine" \
  -o "${bundle_file}"

echo "Wrote ${bundle_file}"
