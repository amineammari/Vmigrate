#!/bin/bash
set -e

echo "Waiting for database..."
for i in {1..30}; do
    python - <<'PY'
import os
import sys

import django
from django.db import connection

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "core.settings")
django.setup()

with connection.cursor() as cursor:
    cursor.execute("SELECT 1")
    cursor.fetchone()
PY
    if [[ $? -eq 0 ]]; then
        break
    fi
    echo "Waiting for database... ($i/30)"
    sleep 2
done

echo "Applying database migrations..."
python manage.py migrate --noinput

echo "Collecting static files..."
python manage.py collectstatic --noinput --clear

exec "$@"