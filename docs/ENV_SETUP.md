Guide d'installation des outils pour déployer sur Kubernetes
=========================================================

Ce document fournit les commandes et instructions pour préparer un poste Linux (Debian/Ubuntu) afin de construire et déployer les images du projet sur un cluster Kubernetes.

Prérequis
- Un utilisateur avec droits sudo
- Connexion Internet

Outils recommandés
- Docker (build & push)
- kubectl (client Kubernetes)
- Helm (package manager)
- kind ou k3s / minikube (cluster local pour tests)
- cert-manager (TLS dans le cluster)
- ingress-nginx (Ingress controller)
- NFS client (si vous utilisez NFS pour stockage)

1) Installer Docker (Debian/Ubuntu)

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
newgrp docker || true
docker --version
```

2) Installer kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

3) Installer Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

4) Installer kind (option: pour cluster local léger)

```bash
curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v0.20.0/kind-$(uname)-amd64"
chmod +x kind
sudo mv kind /usr/local/bin/
kind version
```

Alternatives locales
- k3s: léger, facile à installer pour tests. Voir https://k3s.io
- minikube: alternative, bonne pour desktop.

5) Installer NFS client (si votre stockage est NFS)

```bash
sudo apt install -y nfs-common
```

6) Installer ingress-nginx dans le cluster

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
```

7) Installer cert-manager (pour TLS)

```bash
kubectl create namespace cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --set installCRDs=true
```

8) Installer Prometheus + Grafana (optionnel)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install vmigrate-prom prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
```

9) Installer NFS provisioner (si cluster a accès NFS)

```bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update
helm install nfs-client nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --namespace nfs-provisioner --create-namespace --set nfs.server=<NFS_SERVER_IP> --set nfs.path=/export/path
```

10) Authentification au registre et push des images

```bash
docker login <registry>
# build & push examples (remplacez par votre registry)
docker build --target backend -t myregistry/vmigrate-backend:latest .
docker push myregistry/vmigrate-backend:latest
```

11) Déployer manifests fournis

Copiez les manifests YAML dans un dossier k8s/ puis:

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/backend-deployment.yaml
kubectl apply -f k8s/worker-deployment.yaml
kubectl apply -f k8s/frontend-deployment.yaml
kubectl apply -f k8s/ingress.yaml
```

Script d'automatisation
- Un script d'exemple est fourni dans `scripts/install_k8s_tools.sh`.

Notes de sécurité
- Ne commitez jamais `.env` contenant les secrets.
- Utilisez `kubectl create secret` ou SealedSecrets pour les credentials.

Support & next steps
- Si vous voulez, je génère les manifests k8s/ prêts à déployer et le pipeline GitHub Actions.
