# VM Migrator Container Architecture

## 1. New Architecture Design

VM Migrator is split into two runtimes:

1. **Portable control plane**
   - `frontend`: static Vite/React application served by Nginx.
   - `backend`: Django REST API and admin interface.
   - `redis`: Celery broker/result backend.
   - `db`: MariaDB state store.
   - `beat`: Celery scheduler only; it publishes scheduled jobs but does not run conversion tooling.

2. **Dedicated conversion plane**
   - `conversion-worker`: Celery worker appliance with virt-v2v, qemu-img, libguestfs, nbdkit, VMware VDDK integration, Ansible, Terraform, OpenStack SDK, and VMware SDK support.

The control plane is deliberately free of `/boot`, `/lib/modules`, libvirt sockets,
privileged mode, VDDK, qemu, guestfs, and host-specific paths. It should run on
Docker Desktop for Linux, macOS, or Windows because it only needs normal container
networking and named volumes.

The conversion plane is intentionally Linux-oriented. It joins the same Docker
network (`vm-migrator-control`) and consumes Redis/MariaDB through service DNS:

- `redis:6379`
- `db:3306`
- `backend:8000` when HTTP callbacks are needed

No service uses `host.docker.internal`. The worker and control plane communicate
through Redis task queues and the shared database, not host gateway shortcuts.

## Service Responsibilities

`frontend` owns browser delivery and reverse-proxies `/api` and `/admin` to
`backend`.

`backend` owns HTTP APIs, authentication, database migrations, static collection,
metadata, session state, and task submission.

`beat` owns periodic scheduling only. This keeps scheduled discovery/provisioning
from pulling conversion binaries into the portable image.

`redis` owns queue transport and transient task state.

`db` owns durable application state.

`conversion-worker` owns infrastructure operations: VMware discovery tasks,
virt-v2v/qemu-img conversion, guest inspection/remediation, OpenStack image upload,
Ansible playbooks, and Terraform execution.

## Communication Flow

1. A user submits work through the frontend.
2. The frontend calls the backend over `/api`.
3. The backend records state in MariaDB and publishes Celery tasks to Redis.
4. The conversion worker consumes queues from Redis.
5. The worker performs VMware/OpenStack/conversion work and writes status back to MariaDB.
6. The frontend polls or refreshes through the backend.

The control plane can be started without a conversion worker. Jobs will remain
queued until a worker appliance joins the network.

## 2. Dockerfiles

The Dockerfiles live under `docker/dockerfiles/`:

- `backend.Dockerfile`: Python 3.11 slim image, Django dependencies, Gunicorn,
  backend entrypoint, and backend healthcheck. It has no virtualization packages.
- `frontend.Dockerfile`: Node 20 build stage and Nginx 1.27 runtime stage.
- `conversion-worker.Dockerfile`: Python 3.11 slim Debian image with Debian contrib
  enabled for `nbdkit-plugin-vddk`, plus virt-v2v, qemu-utils, libguestfs, nbdkit,
  libvirt clients, Ansible, Terraform, and validation scripts.

Versions are pinned at image-family and tool level where practical. Debian package
pinning should be handled by an internal mirror or Debian snapshot in production;
pinning every apt package inside the Dockerfile usually creates brittle rebuilds.

## 3. Compose Structure

`docker-compose.yml` is the portable control plane. It uses named volumes, service
DNS, healthchecks, and the fixed network name `vm-migrator-control`.

`docker-compose.conversion.yml` is the conversion appliance. It expects the control
network to exist, which means the control plane should be started first:

```bash
docker compose up -d --build
docker compose -f docker-compose.conversion.yml up -d --build
```

This separation allows the same control plane to run on Windows/macOS while the
conversion worker runs on a Linux host near VMware/OpenStack storage networks.

## 4. Conversion Worker Appliance Design

Containerized in the worker image:

- virt-v2v
- qemu-img/qemu-utils
- libguestfs tools
- nbdkit and VDDK plugin
- libvirt client tools
- OpenStack SDK and VMware SDK Python dependencies
- Ansible runtime
- Terraform binary
- playbooks and Terraform configuration
- startup validation scripts

Still host-dependent:

- Linux kernel behavior needed by qemu/libguestfs workloads.
- CPU, memory, and disk throughput sized for conversion.
- Network reachability to ESXi/vCenter, datastores, OpenStack APIs, and Glance.
- VMware VDDK licensing and distribution process.
- Optional libvirt socket mounts for workflows that truly require host libvirt.
- Optional external storage mounts when artifacts must land on shared NFS/SAN paths.

Do not add privileged mode by default. If a specific conversion path requires
additional device access, enable only that mount/capability in the conversion
compose override and document the reason.

## 5. Startup Validation System

The worker entrypoint runs `/usr/local/bin/conversion-worker-preflight` before
starting Celery. It validates:

- required binaries: `virt-v2v`, `qemu-img`, `guestfish`, `virt-filesystems`,
  `nbdkit`, `terraform`, `ansible-playbook`, and `ssh`
- required env vars: `DATABASE_URL`, `REDIS_URL`, `MIGRATION_OUTPUT_DIR`
- database connectivity through Django
- Redis connectivity
- writable artifact, backup, guestfs cache, and Terraform cache directories
- free disk space via `MIN_CONVERSION_FREE_GB`
- VDDK library directory and nbdkit VDDK plugin when VDDK transport is enabled
- optional OpenStack connectivity from `OS_*` variables
- optional VMware connectivity from `VMWARE_ESXI_*` variables

Set `REQUIRE_PREFLIGHT_CONNECTIVITY=true` when the worker should fail startup if
OpenStack or VMware are unreachable. Leave it false when credentials are supplied
per user/session through the application instead of environment variables.

## 6. Air-Gapped Deployment Strategy

Build connected once, then promote artifacts into the air-gapped environment.

Image workflow:

```bash
docker compose build
docker compose -f docker-compose.conversion.yml build
docker save \
  vm-migrator/backend:${VM_MIGRATOR_VERSION:-local} \
  vm-migrator/frontend:${VM_MIGRATOR_VERSION:-local} \
  vm-migrator/conversion-worker:${VM_MIGRATOR_VERSION:-local} \
  mariadb:10.11.8 redis:7.2.5-alpine nginx:1.27.3-alpine \
  -o offline/images/vm-migrator-images.tar

docker load -i offline/images/vm-migrator-images.tar
```

Internal registry workflow:

```bash
docker tag vm-migrator/backend:local registry.internal/vm-migrator/backend:local
docker tag vm-migrator/frontend:local registry.internal/vm-migrator/frontend:local
docker tag vm-migrator/conversion-worker:local registry.internal/vm-migrator/conversion-worker:local
docker push registry.internal/vm-migrator/backend:local
docker push registry.internal/vm-migrator/frontend:local
docker push registry.internal/vm-migrator/conversion-worker:local
```

Python wheel strategy:

```bash
python -m pip download -r backend/requirements.txt -d offline/wheels
python -m pip download ansible-core==2.17.7 gunicorn==23.0.0 whitenoise==6.8.2 -d offline/wheels
```

For strict offline image builds, copy `offline/wheels` into the build context and
replace online pip installs with:

```bash
python -m pip install --no-index --find-links=/offline/wheels -r /tmp/requirements.txt
```

npm cache strategy:

```bash
cd frontend
npm ci --cache ../offline/npm-cache
npm cache verify --cache ../offline/npm-cache
```

Terraform provider mirror strategy:

```bash
cd terraform
terraform providers lock -platform=linux_amd64
terraform providers mirror ../offline/terraform-providers
```

Set a CLI config in the worker or mount it at runtime:

```hcl
provider_installation {
  filesystem_mirror {
    path    = "/opt/terraform/provider-mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
```

VDDK strategy:

- Store the licensed VDDK archive in `offline/vendor/vddk/` or your internal
  artifact repository.
- Build the conversion worker in a controlled environment that is allowed to
  access that artifact.
- Prefer baking VDDK into the worker image for air-gapped deployments.
- Use a read-only runtime mount only when licensing or operational process forbids
  baking it into the image.

apt strategy:

- Mirror Debian bookworm `main`, `contrib`, `non-free`, and `non-free-firmware`.
- Point `/etc/apt/sources.list.d/debian.sources` to the internal mirror.
- Rebuild images only from the internal mirror after validation.

## 7. Runtime Portability Analysis

Portable:

- frontend
- backend API
- Redis
- MariaDB
- Celery beat
- Docker named volumes and bridge networking

These can run on Linux, macOS, and Windows Docker hosts because they do not need
host kernel modules, libvirt sockets, VDDK, qemu, or privileged containers.

Linux-specific:

- conversion worker
- virt-v2v/qemu-img/libguestfs/nbdkit workflows
- optional libvirt socket integration
- high-throughput local or mounted artifact storage

Windows/macOS hosts can run the control plane. They should not be treated as real
conversion hosts. Docker Desktop uses a Linux VM internally, but conversion jobs
need predictable Linux storage, networking, and performance characteristics.

## 8. Final Production Structure

Recommended structure:

```text
docker/
  dockerfiles/
    backend.Dockerfile
    frontend.Dockerfile
    conversion-worker.Dockerfile
  entrypoints/
    backend.sh
    celery-beat.sh
    conversion-worker.sh
  healthchecks/
    backend-healthcheck.sh
    conversion-worker-healthcheck.sh
  worker/
    preflight.sh
docs/
  container-architecture.md
offline/
  images/
  npm-cache/
  terraform-providers/
  vendor/vddk/
  wheels/
worker/
backend/
frontend/
ansible/
terraform/
docker-compose.yml
docker-compose.conversion.yml
```

This keeps portable application services clean while treating conversion as the
specialized infrastructure runtime it actually is.
