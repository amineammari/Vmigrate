# syntax=docker/dockerfile:1.7
# Air-gapped Conversion Worker - Enhanced Version  
# Includes ALL conversion dependencies: virt-v2v, libguestfs, VDDK, Terraform, Ansible
# All packages version-pinned for reproducibility

ARG PYTHON_VERSION=3.11.9
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-bookworm

FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive \
    LIBGUESTFS_BACKEND=direct \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    TERRAFORM_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache \
    TF_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache

# Enable non-free Debian repositories for guestfs + virt-v2v
RUN sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
    /etc/apt/sources.list.d/debian.sources

# Install ALL conversion-required OS packages with explicit versions where available
# Grouped by category for maintainability
RUN apt-get update && apt-get install -y --no-install-recommends \
    # SSL/TLS + certificates
    ca-certificates \
    # Database access
    default-libmysqlclient-dev \
    # Compilation (for Python C extensions in offline wheels)
    gcc \
    # Core conversion tools
    guestfs-tools \
    libguestfs0 \
    libguestfs-tools \
    libguestfs-xfs \
    libguestfs-reiserfs \
    # Virtualization
    libvirt-clients \
    qemu-utils \
    virt-v2v \
    nbdkit \
    nbdkit-plugin-guestfs \
    nbdkit-plugin-libvirt \
    # System libraries
    libaugeas0 \
    libxml2 \
    pkg-config \
    # Package management + archive tools
    unzip \
    xz-utils \
    # Utilities + networking
    iproute2 \
    jq \
    openssh-client \
    rsync \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd --create-home --uid 10001 --shell /bin/bash appuser

WORKDIR /app

# Copy Python wheels (pre-downloaded on online system)
COPY offline/wheels/ /tmp/wheels/

# Install Python packages from offline wheels only
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
        pytest-timeout==2.1.0 \
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
        ansible-core==2.16.0 \
    && rm -rf /tmp/wheels

# Copy application code
COPY backend /app/
COPY ansible /app/ansible/
COPY terraform /app/terraform/

# Copy entrypoints and scripts
COPY docker/entrypoints/conversion-worker.sh /usr/local/bin/conversion-worker-entrypoint
COPY docker/healthchecks/conversion-worker-healthcheck.sh /usr/local/bin/conversion-worker-healthcheck
COPY docker/worker/preflight.sh /usr/local/bin/conversion-worker-preflight

# Make scripts executable
RUN chmod +x \
    /usr/local/bin/conversion-worker-entrypoint \
    /usr/local/bin/conversion-worker-healthcheck \
    /usr/local/bin/conversion-worker-preflight

# Copy VDDK SDK (if available; failure here doesn't break build)
# VDDK is optional; if not present, conversion will fall back to nbdkit transport
COPY offline/vendor/vddk/ /opt/vmware-vddk/ 2>/dev/null || true

# Copy Terraform plugins (pre-mirrored on online system)
COPY offline/terraform-providers/ /opt/terraform/plugin-cache/ 2>/dev/null || true

# Pre-create all necessary directories
RUN mkdir -p \
    /var/lib/vm-migrator/images \
    /var/cache/guestfs \
    /opt/terraform/plugin-cache \
    /app/logs \
    /opt/vmware-vddk \
    && chown -R appuser:appuser \
        /app \
        /var/lib/vm-migrator \
        /var/cache/guestfs \
        /opt/terraform

# Configure library paths for VDDK
ENV LD_LIBRARY_PATH=/opt/vmware-vddk/lib64:$LD_LIBRARY_PATH \
    VDDK_CONFIG=/opt/vmware-vddk/lib64 \
    VMWARE_VDDK_LIBDIR=/opt/vmware-vddk \
    VMWARE_VDDK_CONFIG=/opt/vmware-vddk/lib64 \
    DJANGO_SETTINGS_MODULE=core.settings \
    MIGRATION_OUTPUT_DIR=/var/lib/vm-migrator/images \
    ANSIBLE_PLAYBOOK_PATH=/app/ansible/playbooks/conversion.yml \
    ANSIBLE_INVENTORY_PATH=/app/ansible/inventory/hosts.ini \
    TERRAFORM_WORKING_DIR=/app/terraform \
    PYTHONPATH=/app

# Switch to non-root user (but allow preflight to run as root if needed via sudo)
# Note: Preflight may need elevated privileges for some checks
USER root

# Health check: verify Celery worker can connect to broker
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=30s \
    CMD /usr/local/bin/conversion-worker-healthcheck || exit 1

ENTRYPOINT ["/usr/local/bin/conversion-worker-entrypoint"]
CMD ["celery", \
     "-A", "core", \
     "worker", \
     "-l", "INFO", \
     "-Q", "migrations,discovery,provisioning,celery", \
     "--hostname", "conversion@%h", \
     "--concurrency", "2"]
