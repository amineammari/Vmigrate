#!/usr/bin/env bash
set -Eeuo pipefail

command -v celery >/dev/null
command -v virt-v2v >/dev/null
command -v qemu-img >/dev/null
command -v nbdkit >/dev/null
command -v terraform >/dev/null
pgrep -f "celery.*worker" >/dev/null
