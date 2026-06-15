#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/keys"

echo "==> Verificando imagem Docker rundeck-ansible:local..."
if ! docker image inspect rundeck-ansible:local &>/dev/null; then
  echo "==> Imagem não encontrada, fazendo build..."
  docker build -t rundeck-ansible:local "$SCRIPT_DIR"
fi

echo "==> Verificando chave SSH..."
mkdir -p "$KEYS_DIR"
if [ ! -f "$KEYS_DIR/rundeck" ]; then
  ssh-keygen -t ed25519 -C "rundeck-local" -f "$KEYS_DIR/rundeck" -N ""
  echo ""
  echo "Chave SSH gerada em $KEYS_DIR/rundeck.pub"
  echo "Instale-a em cada host antes de executar jobs (veja README.md)."
  echo ""
fi

NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "==> Aplicando manifests..."
sed \
  -e "s|ANSIBLE_DIR|$SCRIPT_DIR/ansible|g" \
  -e "s|INVENTORY_DIR|$SCRIPT_DIR/inventory|g" \
  "$SCRIPT_DIR/rundeck.yaml" | kubectl apply -f -

echo "==> Criando secret SSH..."
kubectl create secret generic rundeck-ssh-key \
  --from-file=rundeck="$KEYS_DIR/rundeck" \
  --namespace rundeck \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Configurando URL do Rundeck ($NODE_IP)..."
kubectl set env deployment/rundeck -n rundeck \
  RUNDECK_GRAILS_URL="http://$NODE_IP:30440" > /dev/null

echo "==> Aguardando Rundeck iniciar (pode levar ~2 min)..."
kubectl rollout status deployment/rundeck -n rundeck --timeout=300s

echo ""
echo "Rundeck disponível em: http://$NODE_IP:30440  (admin / admin)"
echo ""
echo "Siga o README.md para configurar o projeto e importar os jobs."
