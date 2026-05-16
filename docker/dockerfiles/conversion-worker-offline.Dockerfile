# syntax=docker/dockerfile:1.7
# Air-gapped conversion worker - includes all VDDK, nbdkit, and dependencies
ARG PYTHON_VERSION=3.11.9
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive \
    LIBGUESTFS_BACKEND=direct \
    TERRAFORM_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache \
    TF_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache

# Enable non-free repositories for libguestfs and virt-v2v
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        default-libmysqlclient-dev \
        gcc \
        guestfs-tools \
        iproute2 \
        jq \
        libaugeas0 \
        libguestfs-tools \
        libguestfs-xfs \
        libguestfs-reiserfs \
        libvirt-clients \
        libxml2 \
        nbdkit \
        nbdkit-plugin-guestfs \
        nbdkit-plugin-libvirt \
        openssh-client \
        pkg-config \
        qemu-utils \
        rsync \
        unzip \
        virt-v2v \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 --shell /bin/bash appuser
WORKDIR /app

# Copy all Python wheels and install from offline cache
COPY offline/wheels/ /tmp/wheels/
RUN python -m pip install --upgrade pip setuptools wheel \
    && python -m pip install --no-index --find-links /tmp/wheels/ \
        -r /tmp/wheels/requirements.txt 2>/dev/null || true \
    && python -m pip install --no-index --find-links /tmp/wheels/ \
        celery amqp asgiref billiard click cryptography decorator django-environ \
        dj-database-url \
        django-cryptography \
        djangorestframework djangorestframework-simplejwt dogpile.cache idna iso8601 \
        jmespath jsonpatch keystoneauth1 kombu openstacksdk os-service-types \
        packaging pbr platformdirs prompt_toolkit psutil psycopg2-binary pycparser \
        mysqlclient \
        pyyaml redis requests requestsexceptions setuptools \
        stevedore typing-extensions wcwidth pyvmomi ansible-core pytest \
        python-dateutil pluggy iniconfig pytest-timeout \
    && rm -rf /tmp/wheels

COPY backend /app
COPY ansible /app/ansible
COPY terraform /app/terraform
COPY offline/vendor/vddk/ /opt/vmware-vddk/
COPY docker/entrypoints/conversion-worker.sh /usr/local/bin/conversion-worker-entrypoint
COPY docker/healthchecks/conversion-worker-healthcheck.sh /usr/local/bin/conversion-worker-healthcheck
COPY docker/worker/preflight.sh /usr/local/bin/conversion-worker-preflight

# If a prebuilt nbdkit VDDK plugin is provided in the offline vendor dir, install it
# into the system nbdkit plugin directory so offline images can load VDDK without
# building the plugin during deploy.
COPY offline/vendor/nbdkit-vddk-plugin.so /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so

RUN chmod +x /usr/local/bin/conversion-worker-entrypoint /usr/local/bin/conversion-worker-healthcheck /usr/local/bin/conversion-worker-preflight \
    && mkdir -p /var/lib/vm-migrator/images /var/cache/guestfs /opt/terraform/plugin-cache /app/logs /opt/vmware-vddk \
        && chown -R appuser:appuser /app /var/lib/vm-migrator /var/cache/guestfs /opt/terraform \
        && if [ -f /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so ]; then \
                 chown root:root /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so && chmod 644 /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so; \
             fi

# Configure LD_LIBRARY_PATH for VDDK libraries
ENV LD_LIBRARY_PATH=/opt/vmware-vddk/lib64:$LD_LIBRARY_PATH \
    VDDK_CONFIG=/opt/vmware-vddk/lib64

USER appuser

ENV DJANGO_SETTINGS_MODULE=core.settings \
    MIGRATION_OUTPUT_DIR=/var/lib/vm-migrator/images \
    ANSIBLE_PLAYBOOK_PATH=/app/ansible/playbooks/conversion.yml \
    ANSIBLE_INVENTORY_PATH=/app/ansible/inventory/hosts.ini \
    TERRAFORM_WORKING_DIR=/app/terraform \
    VMWARE_VDDK_LIBDIR=/opt/vmware-vddk \
    VMWARE_VDDK_CONFIG=/opt/vmware-vddk/lib64

ENTRYPOINT ["/usr/local/bin/conversion-worker-entrypoint"]
CMD ["celery", "-A", "core", "worker", "-l", "INFO", "-Q", "migrations,discovery,provisioning,celery", "--hostname", "conversion@%h"]
