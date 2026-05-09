# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.11.9
ARG TERRAFORM_VERSION=1.7.5
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG TERRAFORM_VERSION=1.7.5

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive \
    LIBGUESTFS_BACKEND=direct \
    TERRAFORM_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache \
    TF_PLUGIN_CACHE_DIR=/opt/terraform/plugin-cache

RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
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

RUN curl -fsSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip \
    && terraform version

RUN useradd --create-home --uid 10001 --shell /bin/bash appuser
WORKDIR /app

COPY backend/requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --upgrade pip==24.2 \
    && python -m pip install -r /tmp/requirements.txt \
    && python -m pip install ansible-core==2.17.7

COPY backend /app
COPY ansible /app/ansible
COPY terraform /app/terraform
COPY offline/vendor/vddk/ /opt/vmware-vddk/
COPY docker/entrypoints/conversion-worker.sh /usr/local/bin/conversion-worker-entrypoint
COPY docker/healthchecks/conversion-worker-healthcheck.sh /usr/local/bin/conversion-worker-healthcheck
COPY docker/worker/preflight.sh /usr/local/bin/conversion-worker-preflight

RUN chmod +x /usr/local/bin/conversion-worker-entrypoint /usr/local/bin/conversion-worker-healthcheck /usr/local/bin/conversion-worker-preflight \
    && mkdir -p /var/lib/vm-migrator/images /var/cache/guestfs /opt/terraform/plugin-cache /app/logs /opt/vmware-vddk \
    && chown -R appuser:appuser /app /var/lib/vm-migrator /var/cache/guestfs /opt/terraform

USER appuser

ENV DJANGO_SETTINGS_MODULE=core.settings \
    MIGRATION_OUTPUT_DIR=/var/lib/vm-migrator/images \
    ANSIBLE_PLAYBOOK_PATH=/app/ansible/playbooks/conversion.yml \
    ANSIBLE_INVENTORY_PATH=/app/ansible/inventory/hosts.ini \
    TERRAFORM_WORKING_DIR=/app/terraform \
    VMWARE_VDDK_LIBDIR=/opt/vmware-vddk

ENTRYPOINT ["/usr/local/bin/conversion-worker-entrypoint"]
CMD ["celery", "-A", "core", "worker", "-l", "INFO", "-Q", "migrations,discovery,provisioning,celery", "--hostname", "conversion@%h"]
