# VMigrate Kubernetes Deployment Guide

This guide explains how to deploy VMigrate with the manifests in this directory.

The current manifests are designed for an air-gapped or offline Kubernetes environment:

- Images are expected to already exist on every Kubernetes node.
- Workloads use `imagePullPolicy: Never`.
- Only the frontend is exposed through Ingress.
- Backend, MariaDB, and Redis are internal `ClusterIP` services.
- Storage currently uses `hostPath` for lab/single-node deployment.

> Production note: `hostPath` is useful for local labs, but it is not a production storage solution. For production or multi-node clusters, replace it with NFS, a CSI driver, or a real dynamic `StorageClass`.

## 1. Architecture

The Kubernetes deployment creates these components:

| Component | File | Kubernetes objects | Purpose |
| --- | --- | --- | --- |
| Namespace | `namespace.yaml` | `Namespace/vmigrate` | Isolates all VMigrate resources |
| Secrets | `secrets.yaml` | `Secret/vmigrate-secrets` | Stores sensitive runtime values |
| Config | `configmap.yaml` | `ConfigMap/vmigrate-config` | Stores non-sensitive application config |
| MariaDB | `mariadb.yaml` | PV, PVC, Deployment, Service | Main database |
| Redis | `redis.yaml` | Deployment, Service | Celery broker and result backend |
| Backend | `backend.yaml` | PV, PVC, Deployment, Service | Django REST API |
| Celery | `celery.yaml` | Worker Deployment, Beat Deployment | Long-running conversion and scheduled tasks |
| Frontend | `frontend.yaml` | Deployment, Service | React/Nginx web UI |
| Ingress | `ingress.yaml` | Ingress | External access to the frontend |

The service names used inside the cluster are:

- MariaDB: `database:3306`
- Redis: `redis:6379`
- Backend API: `backend:8000`
- Frontend: `frontend:80`

The frontend nginx image proxies API traffic to the backend, so users normally access only the frontend Ingress.

## 2. Current Storage Layout

Two persistent volumes are defined with `hostPath`:

| Data | PV | PVC | Host path | Mounted in container |
| --- | --- | --- | --- | --- |
| MariaDB data | `vmigrate-mariadb-pv` | `mariadb-data` | `/mnt/nfs_test/vmigrate-mariadb` | `/var/lib/mysql` |
| Migration artifacts | `vmigrate-artifacts-pv` | `vmigrate-artifacts` | `/mnt/nfs_test/vmigrate-artifacts` | `/var/lib/vm-migrator/images` |

The artifact PVC is used by:

- `backend.yaml`
- `celery.yaml`

Because this is `hostPath` + `ReadWriteOnce`, use this setup mainly on a single-node cluster. If the backend and Celery worker land on different nodes in a multi-node cluster, they may not see the same files.

## 3. Prerequisites

You need:

- A Kubernetes cluster.
- `kubectl` configured for that cluster.
- An ingress controller if you want external access through `ingress.yaml`.
- Enough CPU/RAM for the conversion worker.
- The VMigrate Docker images already loaded on every node.
- Access from the worker/backend pods to VMware and OpenStack endpoints.

The expected images are:

```bash
vm-migrator/backend:offline
vm-migrator/frontend:offline
vm-migrator/conversion-worker:offline
mariadb:10.11.8
redis:7.2.5-alpine
```

## 4. Prepare Docker Images

On the machine where the images exist, export them:

```bash
docker save vm-migrator/backend:offline -o backend.tar
docker save vm-migrator/frontend:offline -o frontend.tar
docker save vm-migrator/conversion-worker:offline -o conversion-worker.tar
docker save mariadb:10.11.8 -o mariadb.tar
docker save redis:7.2.5-alpine -o redis.tar
```

Copy the `.tar` files to every Kubernetes node.

For containerd-based clusters, import them on each node:

```bash
sudo ctr -n k8s.io images import backend.tar
sudo ctr -n k8s.io images import frontend.tar
sudo ctr -n k8s.io images import conversion-worker.tar
sudo ctr -n k8s.io images import mariadb.tar
sudo ctr -n k8s.io images import redis.tar
```

Or with CRI tooling:

```bash
sudo crictl load backend.tar
sudo crictl load frontend.tar
sudo crictl load conversion-worker.tar
sudo crictl load mariadb.tar
sudo crictl load redis.tar
```

Verify images on each node:

```bash
sudo crictl images | grep -E 'vm-migrator|mariadb|redis'
```

If your tags are different, either retag the images or update the `image:` fields in the manifests.

## 5. Prepare Host Directories

Because the current manifests use `hostPath`, create the required directories on the Kubernetes node where the pods will run:

```bash
sudo mkdir -p /mnt/nfs_test/vmigrate-mariadb
sudo mkdir -p /mnt/nfs_test/vmigrate-artifacts
```

MariaDB runs with group `999`, and the backend runs with user/group `10001`. For a simple lab setup, you can make the directories writable:

```bash
sudo chmod -R 0777 /mnt/nfs_test/vmigrate-mariadb
sudo chmod -R 0777 /mnt/nfs_test/vmigrate-artifacts
```

For a stricter setup, use ownership and permissions that match your cluster runtime and security policy.

## 6. Edit Configuration

Before deployment, edit these files.

### `secrets.yaml`

Replace every `CHANGE_ME...` value:

```yaml
SECRET_KEY
JWT_SECRET
DB_USER
DB_PASSWORD
DB_ROOT_PASSWORD
DATABASE_URL
DEFAULT_SUPERADMIN_PASSWORD
VMWARE_ESXI_USERNAME
VMWARE_ESXI_PASSWORD
VMWARE_VDDK_THUMBPRINT
OS_USERNAME
OS_PASSWORD
TERRAFORM_DEFAULT_VARS_JSON
```

The `DATABASE_URL` must use the same DB username and password:

```text
mysql://<DB_USER>:<DB_PASSWORD>@database:3306/vm_migrator?charset=utf8mb4
```

Do not commit real secrets.

### `configmap.yaml`

Review these values:

```yaml
ALLOWED_HOSTS
VMWARE_ESXI_HOST
VMWARE_ESXI_PORT
VMWARE_ESXI_INSECURE
OS_AUTH_URL
OS_PROJECT_NAME
OS_REGION_NAME
OS_VERIFY
OPENSTACK_DEFAULT_NETWORK
OPENSTACK_DEFAULT_EXTERNAL_NETWORK
```

For the current non-NFS lab setup, these are already disabled:

```yaml
NFS_ENABLED: "false"
NFS_VALIDATE_MOUNT: "false"
```

The container artifact path remains:

```yaml
MIGRATION_OUTPUT_DIR: "/var/lib/vm-migrator/images"
NFS_PATH: "/var/lib/vm-migrator/images"
ARTIFACT_BACKUP_DIR: "/var/lib/vm-migrator/images/backups"
```

### `ingress.yaml`

Update the host if needed:

```yaml
host: vmigrate.local
```

Update the ingress class if your cluster does not use nginx:

```yaml
ingressClassName: nginx
```

## 7. Deploy

From the repository root:

```bash
cd kubernetes
```

Apply the namespace first:

```bash
kubectl apply -f namespace.yaml
```

Apply secrets and config:

```bash
kubectl apply -f secrets.yaml
kubectl apply -f configmap.yaml
```

Apply the database and Redis:

```bash
kubectl apply -f mariadb.yaml
kubectl apply -f redis.yaml
```

Wait for them:

```bash
kubectl -n vmigrate rollout status deployment/mariadb
kubectl -n vmigrate rollout status deployment/redis
```

Apply backend and Celery:

```bash
kubectl apply -f backend.yaml
kubectl apply -f celery.yaml
```

Wait for them:

```bash
kubectl -n vmigrate rollout status deployment/backend
kubectl -n vmigrate rollout status deployment/celery-worker
kubectl -n vmigrate rollout status deployment/celery-beat
```

Apply frontend and ingress:

```bash
kubectl apply -f frontend.yaml
kubectl apply -f ingress.yaml
```

Wait for frontend:

```bash
kubectl -n vmigrate rollout status deployment/frontend
```

## 8. Verify

Check all objects:

```bash
kubectl -n vmigrate get pods -o wide
kubectl -n vmigrate get svc
kubectl -n vmigrate get pv
kubectl -n vmigrate get pvc
kubectl -n vmigrate get ingress
```

Expected pods:

```text
mariadb-...
redis-...
backend-...
celery-worker-...
celery-beat-...
frontend-...
frontend-...
```

Check persistent claims:

```bash
kubectl -n vmigrate get pvc
```

Expected:

```text
mariadb-data          Bound
vmigrate-artifacts    Bound
```

Check logs:

```bash
kubectl -n vmigrate logs deployment/mariadb
kubectl -n vmigrate logs deployment/redis
kubectl -n vmigrate logs deployment/backend
kubectl -n vmigrate logs deployment/celery-worker
kubectl -n vmigrate logs deployment/celery-beat
kubectl -n vmigrate logs deployment/frontend
```

Check backend health from inside the cluster:

```bash
kubectl -n vmigrate run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -I http://backend:8000/admin/login/
```

If your cluster is offline and does not have `curlimages/curl`, use an existing pod:

```bash
kubectl -n vmigrate exec deployment/frontend -- wget -S -O- http://backend:8000/admin/login/
```

## 9. Access The Application

Get the Ingress:

```bash
kubectl -n vmigrate get ingress vmigrate
```

If the host is `vmigrate.local`, add a DNS record or local hosts entry:

```text
<INGRESS_IP> vmigrate.local
```

Then open:

```text
http://vmigrate.local
```

If you do not have an ingress controller yet, use port-forward for testing:

```bash
kubectl -n vmigrate port-forward service/frontend 8080:80
```

Then open:

```text
http://localhost:8080
```

## 10. Common Problems

### Pod is `ImagePullBackOff` or `ErrImageNeverPull`

Cause: the image is not loaded on the node where the pod is scheduled.

Check:

```bash
kubectl -n vmigrate describe pod <pod-name>
```

Fix: import the required image on that node, or change the `image:` tag to match the image that exists locally.

### PVC is not `Bound`

Check PV/PVC:

```bash
kubectl get pv
kubectl -n vmigrate get pvc
kubectl -n vmigrate describe pvc mariadb-data
kubectl -n vmigrate describe pvc vmigrate-artifacts
```

For the current manifests, the PVCs bind directly to:

```yaml
volumeName: vmigrate-mariadb-pv
volumeName: vmigrate-artifacts-pv
```

Also check that the storage class names match:

```yaml
storageClassName: standard
```

### Pod stuck in `ContainerCreating`

Common causes:

- Host path directory missing.
- Permission problem on `/mnt/nfs_test/...`.
- PVC not bound.
- Image missing.

Check:

```bash
kubectl -n vmigrate describe pod <pod-name>
```

### Backend is not ready

Check logs:

```bash
kubectl -n vmigrate logs deployment/backend
```

Common causes:

- Bad `DATABASE_URL`.
- MariaDB not ready.
- Wrong `SECRET_KEY` or missing secrets.
- Django migrations failed.
- `ALLOWED_HOSTS` missing your hostname.

### Celery worker is not ready

Check:

```bash
kubectl -n vmigrate logs deployment/celery-worker
kubectl -n vmigrate describe pod -l app.kubernetes.io/name=celery-worker
```

Common causes:

- Redis not reachable.
- Conversion image missing tools.
- VDDK missing or misconfigured.
- Not enough memory.
- Cluster policy blocks privileged containers.

The worker is privileged because conversion uses qemu/libguestfs tooling. In hardened clusters, this may require special policy.

### Frontend works but API fails

Check backend:

```bash
kubectl -n vmigrate get pods -l app.kubernetes.io/name=backend
kubectl -n vmigrate logs deployment/backend
```

Check the internal service:

```bash
kubectl -n vmigrate get svc backend
```

The frontend should proxy `/api` and `/admin` to:

```text
backend:8000
```

### Ingress does not work

Check:

```bash
kubectl -n vmigrate describe ingress vmigrate
kubectl get ingressclass
kubectl get pods -A | grep -i ingress
```

Common causes:

- No ingress controller installed.
- Wrong `ingressClassName`.
- DNS or `/etc/hosts` not pointing to the ingress IP.
- Firewall blocking HTTP/HTTPS.

## 11. Useful Operations

Restart a deployment:

```bash
kubectl -n vmigrate rollout restart deployment/backend
kubectl -n vmigrate rollout restart deployment/celery-worker
```

Watch pods:

```bash
kubectl -n vmigrate get pods -w
```

Open a shell in the backend:

```bash
kubectl -n vmigrate exec -it deployment/backend -- /bin/sh
```

Open a shell in the worker:

```bash
kubectl -n vmigrate exec -it deployment/celery-worker -- /bin/bash
```

Check artifact files:

```bash
kubectl -n vmigrate exec -it deployment/backend -- ls -lah /var/lib/vm-migrator/images
```

Check MariaDB service DNS:

```bash
kubectl -n vmigrate exec -it deployment/backend -- getent hosts database
```

Check Redis service DNS:

```bash
kubectl -n vmigrate exec -it deployment/backend -- getent hosts redis
```

## 12. Update Deployment

If you rebuild an image but keep the same tag, reload the image on every node, then restart the deployment:

```bash
kubectl -n vmigrate rollout restart deployment/backend
kubectl -n vmigrate rollout restart deployment/celery-worker
kubectl -n vmigrate rollout restart deployment/frontend
```

If you change a ConfigMap or Secret, apply it and restart affected pods:

```bash
kubectl apply -f configmap.yaml
kubectl apply -f secrets.yaml
kubectl -n vmigrate rollout restart deployment/backend
kubectl -n vmigrate rollout restart deployment/celery-worker
kubectl -n vmigrate rollout restart deployment/celery-beat
kubectl -n vmigrate rollout restart deployment/frontend
```

## 13. Delete Deployment

Delete workloads:

```bash
kubectl delete -f ingress.yaml
kubectl delete -f frontend.yaml
kubectl delete -f celery.yaml
kubectl delete -f backend.yaml
kubectl delete -f redis.yaml
kubectl delete -f mariadb.yaml
```

Delete config and namespace:

```bash
kubectl delete -f configmap.yaml
kubectl delete -f secrets.yaml
kubectl delete -f namespace.yaml
```

Because the PV reclaim policy is `Retain`, deleting the PVC does not automatically delete the host data. Clean it manually only when you are sure:

```bash
sudo rm -rf /mnt/nfs_test/vmigrate-mariadb
sudo rm -rf /mnt/nfs_test/vmigrate-artifacts
```

## 14. Production Changes To Make Later

Before using this in production, replace or improve:

- Replace `hostPath` with NFS, Ceph, Longhorn, OpenEBS, or another CSI-backed storage provider.
- Use a registry inside your network instead of manually loading images, or keep the offline import process documented.
- Store secrets with Vault, External Secrets, or Sealed Secrets.
- Add TLS to Ingress.
- Add NetworkPolicies.
- Restrict the privileged worker to dedicated nodes.
- Add node selectors/affinity so storage and conversion pods run where expected.
- Add monitoring for pods, Celery queue depth, Redis, MariaDB, disk usage, and migration duration.
- Add backups for MariaDB and migration artifacts.
- Tune CPU/memory based on real VM disk sizes.

