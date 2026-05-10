# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.11.9
FROM python:${PYTHON_VERSION}-slim-bookworm AS python-base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ansible \
        curl \
        default-libmysqlclient-dev \
        gcc \
        gnupg \
        libguestfs-tools \
        nbdkit \
        openssh-client \
        pkg-config \
        qemu-utils \
        virt-v2v \
    && rm -rf /var/lib/apt/lists/*

# Install Terraform from HashiCorp repository
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add - \
    && echo "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends terraform \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser
WORKDIR /app

COPY backend/requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --upgrade pip==24.2 \
    && python -m pip install -r /tmp/requirements.txt \
    && python -m pip install gunicorn==23.0.0 whitenoise==6.8.2

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
