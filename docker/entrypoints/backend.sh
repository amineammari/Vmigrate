#!/usr/bin/env bash
set -Eeuo pipefail

wait_for_django_db() {
  local attempts="${DB_WAIT_ATTEMPTS:-60}"
  local delay="${DB_WAIT_DELAY_SECONDS:-2}"

  echo "Waiting for database connectivity..."
  for attempt in $(seq 1 "${attempts}"); do
    if python manage.py check --database default >/tmp/django-db-check.out 2>&1; then
      return 0
    fi
    echo "Database not ready (${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
  done

  cat /tmp/django-db-check.out >&2 || true
  echo "Database did not become ready in time." >&2
  return 1
}

wait_for_django_db

echo "Applying database migrations..."
python manage.py migrate --noinput

echo "Collecting static files..."
python manage.py collectstatic --noinput --clear

exec "$@"
