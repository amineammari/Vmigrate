# Docker Image Layout

This project intentionally uses separate Dockerfiles instead of one mixed
multi-stage file:

- `docker/dockerfiles/backend.Dockerfile` builds the portable Django API image.
- `docker/dockerfiles/frontend.Dockerfile` builds the portable Vite/Nginx UI image.
- `docker/dockerfiles/conversion-worker.Dockerfile` builds the Linux conversion
  appliance with virt-v2v, qemu-img, libguestfs, nbdkit, Ansible, and Terraform.

Use `docker-compose.yml` for the portable control plane. Use
`docker-compose.conversion.yml` only on Linux conversion hosts where the worker
runtime is expected to run real VM conversion jobs.
