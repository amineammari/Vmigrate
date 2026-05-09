#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${SKIP_CONVERSION_PREFLIGHT:-false}" != "true" ]]; then
  /usr/local/bin/conversion-worker-preflight
fi

concurrency="${CELERY_WORKER_CONCURRENCY:-2}"
prefetch="${CELERY_WORKER_PREFETCH_MULTIPLIER:-1}"
max_tasks="${CELERY_WORKER_MAX_TASKS_PER_CHILD:-50}"
soft_limit="${CELERY_TASK_SOFT_TIME_LIMIT:-7200}"
hard_limit="${CELERY_TASK_TIME_LIMIT:-7500}"

exec "$@" \
  --concurrency="${concurrency}" \
  --prefetch-multiplier="${prefetch}" \
  --max-tasks-per-child="${max_tasks}" \
  --soft-time-limit="${soft_limit}" \
  --time-limit="${hard_limit}"
