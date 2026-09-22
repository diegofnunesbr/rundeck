#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/keys"

echo "==> Verificando imagem Docker rundeck-ansible:local..."
if ! docker image inspect rundeck-ansible:local &>/dev/null; then
  echo "==> Imagem não encontrada, fazendo build..."
  docker build -t rundeck-ansible:local "$SCRIPT_DIR"
fi

echo "==> Importando imagem para o containerd do k0s..."
docker save rundeck-ansible:local | sudo k0s ctr images import -

echo "==> Verificando chave SSH..."
mkdir -p "$KEYS_DIR"
if [ ! -f "$KEYS_DIR/rundeck" ]; then
  ssh-keygen -t ed25519 -C "rundeck-local" -f "$KEYS_DIR/rundeck" -N ""
  echo ""
  echo "Chave SSH gerada em $KEYS_DIR/rundeck.pub"
  echo "Instale-a em cada host antes de executar jobs (veja README.md)."
  echo ""
fi

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

echo "==> Configurando URL do Rundeck..."
kubectl set env deployment/rundeck -n rundeck \
  RUNDECK_GRAILS_URL="https://rundeck.diegofnunesbr.com" > /dev/null

echo "==> Aguardando Rundeck iniciar (pode levar ~2 min)..."
kubectl rollout status deployment/rundeck -n rundeck --timeout=300s

echo ""
echo "Rundeck vai ficar disponível em https://rundeck.diegofnunesbr.com"
echo "assim que cert-manager/ingress-nginx/dns estiverem prontos (ver"
echo "repositório argocd). Até lá, ou pra configurar o projeto agora,"
echo "use port-forward:"
echo ""
echo "  kubectl -n rundeck port-forward svc/rundeck 30440:4440"
echo "  (admin / admin em http://localhost:30440)"
echo ""
echo "Siga o README.md para configurar o projeto e importar os jobs."
