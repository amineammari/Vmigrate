# syntax=docker/dockerfile:1.7
# Air-gapped backend server - all dependencies vendored offline
ARG PYTHON_VERSION=3.11.9
FROM python:${PYTHON_VERSION}-slim-bookworm AS python-base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        default-libmysqlclient-dev \
        gcc \
        openssh-client \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser
WORKDIR /app

# Copy offline wheels and install from cache
COPY offline/wheels/ /tmp/wheels/
RUN python -m pip install --upgrade pip setuptools wheel \
    && python -m pip install --no-index --find-links /tmp/wheels/ \
        celery amqp asgiref billiard click cryptography decorator django-environ \
        dj-database-url \
        django-cryptography \
        djangorestframework djangorestframework-simplejwt dogpile.cache idna iso8601 \
        jmespath jsonpatch keystoneauth1 kombu openstacksdk os-service-types \
        packaging pbr platformdirs prompt_toolkit psutil psycopg2-binary pycparser \
        mysqlclient \
        pyyaml redis requests requestsexceptions setuptools \
        stevedore typing-extensions wcwidth pyvmomi pytest \
        python-dateutil pluggy iniconfig gunicorn whitenoise \
    && rm -rf /tmp/wheels

COPY backend /app
COPY docker/entrypoints/backend.sh /usr/local/bin/backend-entrypoint
COPY docker/entrypoints/celery-beat.sh /usr/local/bin/celery-beat-entrypoint
COPY docker/entrypoints/celery-worker.sh /usr/local/bin/celery-worker-entrypoint
COPY docker/healthchecks/backend-healthcheck.sh /usr/local/bin/backend-healthcheck

RUN chmod +x /usr/local/bin/backend-entrypoint /usr/local/bin/celery-beat-entrypoint /usr/local/bin/celery-worker-entrypoint /usr/local/bin/backend-healthcheck \
    && mkdir -p /app/staticfiles /app/logs /var/lib/vm-migrator/beat \
    && chown -R appuser:appuser /app /var/lib/vm-migrator

USER appuser
EXPOSE 8000

ENV DJANGO_SETTINGS_MODULE=core.settings
ENTRYPOINT ["/usr/local/bin/backend-entrypoint"]
CMD ["gunicorn", "core.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--access-logfile", "-", "--error-logfile", "-"]
