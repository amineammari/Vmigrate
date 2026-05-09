#!/usr/bin/env bash
set -Eeuo pipefail

exec celery -A core beat \
  -l "${CELERY_BEAT_LOG_LEVEL:-INFO}" \
  --scheduler celery.beat:PersistentScheduler \
  --schedule /var/lib/vm-migrator/beat/celerybeat-schedule
