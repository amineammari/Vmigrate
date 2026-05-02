# ---- Base Python Image ----
FROM python:3.11-slim AS base

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gcc \
        libpq-dev \
        curl \
        default-libmysqlclient-dev \
        pkg-config \
        && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1001 appuser
WORKDIR /app

COPY backend/requirements.txt /app/requirements.txt
RUN pip install --upgrade pip && pip install --no-cache-dir -r requirements.txt

# ---- Backend (Django API) ----
FROM base AS backend

WORKDIR /app

# Copy only backend code and entrypoint
COPY backend /app
COPY entrypoint.sh /entrypoint.sh

# Install gunicorn and whitenoise for static file serving
RUN pip install --no-cache-dir gunicorn whitenoise

# Set permissions for entrypoint and static/media dirs
RUN chmod +x /entrypoint.sh && \
    mkdir -p /app/staticfiles /app/logs /app/images

EXPOSE 8000

ENV DJANGO_SETTINGS_MODULE=core.settings

ENTRYPOINT ["/entrypoint.sh"]
CMD ["gunicorn", "core.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3"]

# ---- Worker (Celery - VM conversion with virt-v2v) ----
FROM base AS worker

# nbdkit's VDDK plugin is packaged in Debian contrib.
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources

# Install conversion tools, libvirt, and infrastructure tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-client \
        unzip \
        virt-v2v \
        libvirt-clients \
        qemu-utils \
        libguestfs-tools \
        libguestfs-xfs \
        libguestfs-reiserfs \
        nbdkit \
        nbdkit-plugin-vddk \
        libxml2 \
        libaugeas0 \
        && rm -rf /var/lib/apt/lists/*

# Install Terraform (official binary)
ENV TERRAFORM_VERSION=1.7.5
RUN curl -fsSL https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip -o terraform.zip \
    && unzip terraform.zip -d /usr/local/bin \
    && rm terraform.zip

# Install Ansible for playbook-based conversions
RUN pip install --no-cache-dir ansible

WORKDIR /app
COPY backend /app

# Create necessary directories for virt-v2v cache
RUN mkdir -p /var/cache/guestfs && \
    chmod 777 /var/cache/guestfs

CMD ["celery", "-A", "core", "worker", "-l", "info", "--concurrency=2", "--loglevel=INFO", "--max-tasks-per-child=100", "--time-limit=600"]

# ---- Frontend (Vite + Nginx) ----
FROM node:20-slim AS frontend-build

WORKDIR /app
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install --frozen-lockfile
COPY frontend /app
RUN npm run build

FROM nginx:1.25-alpine AS frontend
COPY --from=frontend-build /app/dist /usr/share/nginx/html
COPY frontend/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
