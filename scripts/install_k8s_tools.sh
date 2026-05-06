#!/usr/bin/env bash
# Script d'installation des outils essentiels pour déploiement Kubernetes (Debian/Ubuntu)
set -euo pipefail

echo "Début de l'installation des outils Kubernetes/Docker..."

if [ "$(id -u)" -ne 0 ]; then
  echo "Ce script nécessite sudo. Relancez avec sudo." >&2
  exit 1
fi

apt update
apt install -y ca-certificates curl gnupg lsb-release software-properties-common

# Docker
echo "Installation de Docker..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# kubectl
echo "Installation de kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Helm
echo "Installation de Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kind
echo "Installation de kind..."
curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v0.20.0/kind-$(uname)-amd64"
chmod +x kind
mv kind /usr/local/bin/

# NFS client
echo "Installation NFS client..."
apt install -y nfs-common

echo "Installation terminée. Ajoutez votre utilisateur au groupe docker si nécessaire: sudo usermod -aG docker $SUDO_USER"
echo "Relancez la session utilisateur ou exécutez: newgrp docker"

echo "Utilisez 'kind create cluster' ou installez k3s/minikube selon vos besoins."

exit 0
