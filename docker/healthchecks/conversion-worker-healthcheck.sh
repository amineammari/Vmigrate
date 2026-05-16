#!/usr/bin/env bash
set -Eeuo pipefail

command -v celery >/dev/null
command -v virt-v2v >/dev/null
command -v qemu-img >/dev/null
command -v nbdkit >/dev/null
if [[ "${ENABLE_TERRAFORM_FROM_CELERY:-false}" =~ ^(1|true|yes)$ ]]; then
	command -v terraform >/dev/null
fi
pgrep -f "celery.*worker" >/dev/null
