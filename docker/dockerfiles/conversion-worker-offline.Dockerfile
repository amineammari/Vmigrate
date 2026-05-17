# syntax=docker/dockerfile:1.7
# Air-gapped conversion worker — fully self-contained virt-v2v/VDDK/libguestfs stack.
ARG PYTHON_VERSION=3.11.9
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive \
    LIBGUESTFS_BACKEND=direct \
    LIBGUESTFS_BACKEND_SETTINGS=force_tcg \
    LIBGUESTFS_MEMSIZE=768 \
    LIBGUESTFS_CPUS=1 \
    LIBGUESTFS_SMP=1 \
    VIRT_V2V_NBDKIT_THREADS=1 \
    LIBGUESTFS_TOOLS_CONF=/etc/libguestfs-tools.conf \
    EMBEDDED_KERNEL_ROOT=/usr/lib/vm-migrator/kernels \
    SUPERMIN_KERNEL=/usr/lib/vm-migrator/kernels/vmlinuz \
    TERRAFORM_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache \
    TF_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache \
    VMWARE_VDDK_LIBDIR=/opt/vmware-vddk \
    VMWARE_VDDK_CONFIG=/opt/vmware-vddk/lib64

# All runtime packages installed at image build time (no apt at deploy).
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        default-libmysqlclient-dev \
        gcc \
        genisoimage \
        guestfish \
        guestfs-tools \
        iproute2 \
        jq \
        libaugeas0 \
        libguestfs0 \
        libguestfs-tools \
        libguestfs-reiserfs \
        libguestfs-xfs \
        libosinfo-bin \
        libvirt-clients \
        libxml2 \
        linux-image-amd64 \
        linux-headers-amd64 \
        nbdkit \
        nbdkit-plugin-guestfs \
        nbdkit-plugin-libvirt \
        openssh-client \
        pkg-config \
        python3-openstackclient \
        qemu-system-x86 \
        qemu-utils \
        rsync \
        supermin \
        unzip \
        virt-v2v \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Offline Python wheels
COPY offline/wheels/ /tmp/wheels/
RUN python -m pip install --upgrade pip setuptools wheel \
    && python -m pip install --no-index --find-links /tmp/wheels/ \
        -r /tmp/wheels/requirements.txt 2>/dev/null || true \
    && python -m pip install --no-index --find-links /tmp/wheels/ \
        celery amqp asgiref billiard click cryptography decorator django-environ \
        dj-database-url django-cryptography djangorestframework djangorestframework-simplejwt \
        dogpile.cache idna iso8601 jmespath jsonpatch keystoneauth1 kombu openstacksdk \
        os-service-types packaging pbr platformdirs prompt_toolkit psutil psycopg2-binary \
        pycparser mysqlclient pyyaml redis requests requestsexceptions setuptools \
        stevedore typing-extensions wcwidth pyvmomi ansible-core pytest python-dateutil \
        pluggy iniconfig pytest-timeout \
    && rm -rf /tmp/wheels

COPY backend /app
COPY ansible /app/ansible
COPY terraform /app/terraform
COPY offline/vendor/terraform/terraform /usr/local/bin/terraform
COPY offline/vendor/vddk/ /opt/vmware-vddk/
COPY offline/vendor/nbdkit-vddk-plugin.so /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so

COPY docker/libguestfs-tools.conf /etc/libguestfs-tools.conf
COPY docker/scripts/vddk-sanitize-libcxx.sh /usr/local/bin/vddk-sanitize-libcxx
COPY docker/scripts/embed-container-kernel.sh /usr/local/bin/embed-container-kernel
COPY docker/scripts/write-libguestfs-tools-conf.sh /usr/local/bin/write-libguestfs-tools-conf
COPY docker/scripts/setup-embedded-kernel-runtime.sh /usr/local/bin/setup-embedded-kernel-runtime
COPY docker/entrypoints/conversion-worker.sh /usr/local/bin/conversion-worker-entrypoint
COPY docker/healthchecks/conversion-worker-healthcheck.sh /usr/local/bin/conversion-worker-healthcheck
COPY docker/worker/preflight.sh /usr/local/bin/conversion-worker-preflight

RUN chmod +x /usr/local/bin/vddk-sanitize-libcxx \
        /usr/local/bin/embed-container-kernel \
        /usr/local/bin/write-libguestfs-tools-conf \
        /usr/local/bin/setup-embedded-kernel-runtime \
        /usr/local/bin/conversion-worker-entrypoint \
        /usr/local/bin/conversion-worker-healthcheck \
        /usr/local/bin/conversion-worker-preflight \
        /usr/local/bin/terraform \
    && /usr/local/bin/vddk-sanitize-libcxx /opt/vmware-vddk/lib64 \
    && /usr/local/bin/embed-container-kernel /usr/lib/vm-migrator/kernels \
    && LIBGUESTFS_CPUS=1 LIBGUESTFS_MEMSIZE=768 /usr/local/bin/write-libguestfs-tools-conf /etc/libguestfs-tools.conf \
    && mkdir -p /var/lib/vm-migrator/images /var/cache/guestfs /opt/terraform/plugin-cache /app/logs \
    && if [ -f /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so ]; then \
         chmod 644 /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so; \
       fi \
    && if [ -f /opt/vmware-vddk/lib64/libdiskLibPlugin.so ] \
         && [ ! -e /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so ]; then \
         ln -sf /opt/vmware-vddk/lib64/libdiskLibPlugin.so \
           /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so; \
       fi

# Conversion worker runs as root (privileged libguestfs/qemu); Django app code is read-only.
ENV DJANGO_SETTINGS_MODULE=core.settings \
    MIGRATION_OUTPUT_DIR=/var/lib/vm-migrator/images \
    ANSIBLE_PLAYBOOK_PATH=/app/ansible/playbooks/conversion.yml \
    ANSIBLE_INVENTORY_PATH=/app/ansible/inventory/hosts.ini \
    TERRAFORM_WORKING_DIR=/app/terraform \
    PREFLIGHT_STRICT=false \
    REQUIRE_PREFLIGHT_CONNECTIVITY=false

USER root
ENTRYPOINT ["/usr/local/bin/conversion-worker-entrypoint"]
CMD ["celery", "-A", "core", "worker", "-l", "INFO", "-Q", "migrations,discovery,provisioning,celery", "--hostname", "conversion@%h"]
