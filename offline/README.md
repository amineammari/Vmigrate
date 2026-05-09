# Offline Artifact Staging

Use this directory to stage air-gapped deployment artifacts:

- `images/`: `docker save` archives.
- `wheels/`: Python wheels downloaded with `pip download`.
- `npm-cache/`: npm cache populated by `npm ci --cache`.
- `terraform-providers/`: provider mirror from `terraform providers mirror`.
- `vendor/vddk/`: licensed VMware VDDK archive or extracted runtime.

Do not commit proprietary VDDK payloads, credentials, image archives, or Terraform
state files.
