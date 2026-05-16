# syntax=docker/dockerfile:1.7
# Air-gapped Backend Server - Enhanced Version
# All dependencies vendored offline with explicit version pinning
# Hardened for zero-internet deployment

ARG PYTHON_VERSION=3.11.9
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-bookworm

FROM ${BASE_IMAGE} as dependencies

# Strict reproducibility: disable Python cache and pip version checking
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_NO_INPUT=1

# Install only build-essentials required for wheel compilation
# These packages are only needed during build, not runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        default-libmysqlclient-dev \
        gcc \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Verify pip + setuptools before installing wheels
RUN python -m pip install --upgrade --no-index pip setuptools wheel

# ============================================================================
# RUNTIME STAGE: Minimal production image
# ============================================================================
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# Install ONLY runtime OS dependencies (no build tools)
# openssh-client needed for terraform remote-exec + ansible
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        default-libmysqlclient-dev \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser

WORKDIR /app

# Copy offline wheels from build context (pre-downloaded with pip wheel)
# All wheels must be pre-downloaded on online system:
#   pip wheel -r backend/requirements.txt --no-deps -w offline/wheels/
COPY offline/wheels/ /tmp/wheels/

# Install all Python packages from local wheels only (no PyPI)
RUN python -m pip install --upgrade pip setuptools wheel \
    && python -m pip install \
        --no-index \
        --find-links /tmp/wheels/ \
        --no-cache-dir \
        celery==5.6.2 \
        amqp==5.3.1 \
        asgiref==3.11.1 \
        billiard==4.2.4 \
        certifi==2026.1.4 \
        cffi==2.0.0 \
        charset-normalizer==3.4.4 \
        click==8.3.1 \
        click-didyoumean==0.3.1 \
        click-plugins==1.1.1.2 \
        click-repl==0.3.0 \
        cryptography==46.0.5 \
        decorator==5.2.1 \
        dj-database-url==3.1.0 \
        django-appconf==1.2.0 \
        django-cryptography==1.1 \
        django-environ==0.12.0 \
        Django==4.2.16 \
        djangorestframework==3.16.1 \
        djangorestframework-simplejwt==5.5.1 \
        dogpile.cache==1.5.0 \
        gunicorn==21.2.0 \
        idna==3.11 \
        iniconfig==2.3.0 \
        iso8601==2.1.0 \
        jmespath==1.1.0 \
        jsonpatch==1.33 \
        jsonpointer==3.0.0 \
        keystoneauth1==5.13.0 \
        kombu==5.6.2 \
        mysqlclient==2.2.8 \
        openstacksdk==4.9.0 \
        os-service-types==1.8.2 \
        packaging==26.0 \
        pbr==7.0.3 \
        platformdirs==4.6.0 \
        pluggy==1.6.0 \
        prompt_toolkit==3.0.52 \
        psutil==7.2.2 \
        psycopg2-binary==2.9.11 \
        pycparser==3.0 \
        Pygments==2.20.0 \
        PyJWT==2.12.1 \
        pytest==9.0.2 \
        python-dateutil==2.9.0.post0 \
        pyvmomi==9.0.0.0 \
        PyYAML==6.0.3 \
        redis==7.1.1 \
        requests==2.32.5 \
        requestsexceptions==1.4.0 \
        setuptools==82.0.0 \
        stevedore==7.0.0 \
        typing-extensions==4.14.0 \
        wcwidth==0.2.13 \
        whitenoise==6.8.2 \
    && rm -rf /tmp/wheels

# Copy application code
COPY backend /app/
COPY docker/entrypoints/backend.sh /usr/local/bin/backend-entrypoint
COPY docker/entrypoints/celery-beat.sh /usr/local/bin/celery-beat-entrypoint
COPY docker/entrypoints/celery-worker.sh /usr/local/bin/celery-worker-entrypoint
COPY docker/healthchecks/backend-healthcheck.sh /usr/local/bin/backend-healthcheck

# Make entrypoints executable
RUN chmod +x \
    /usr/local/bin/backend-entrypoint \
    /usr/local/bin/celery-beat-entrypoint \
    /usr/local/bin/celery-worker-entrypoint \
    /usr/local/bin/backend-healthcheck

# Pre-create all necessary directories with proper ownership
RUN mkdir -p \
    /app/staticfiles \
    /app/logs \
    /var/lib/vm-migrator/beat \
    && chown -R appuser:appuser /app /var/lib/vm-migrator

# Switch to non-root user
USER appuser

# Health check: verify Django can access database and serve HTTP
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=10s \
    CMD /usr/local/bin/backend-healthcheck || exit 1

EXPOSE 8000

ENV DJANGO_SETTINGS_MODULE=core.settings \
    PYTHONPATH=/app

ENTRYPOINT ["/usr/local/bin/backend-entrypoint"]
CMD ["gunicorn", \
     "core.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "3", \
     "--worker-class", "sync", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--log-level", "info"]
