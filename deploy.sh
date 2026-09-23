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

echo "==> Criando namespace e secret SSH..."
kubectl create namespace rundeck --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic rundeck-ssh-key \
  --from-file=rundeck="$KEYS_DIR/rundeck" \
  --namespace rundeck \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Aplicando Application do Argo CD..."
kubectl apply -f "$SCRIPT_DIR/applications/argocd.rundeck.yaml"

echo "==> Aguardando Rundeck iniciar (pode levar ~2 min)..."
until kubectl -n rundeck get deployment rundeck >/dev/null 2>&1; do sleep 5; done
kubectl -n rundeck get secret rundeck-realm >/dev/null 2>&1 || sleep 30
if ! kubectl -n rundeck get secret rundeck-realm >/dev/null 2>&1; then
  echo ""
  echo "O secret rundeck-realm (senha do admin) não existe neste cluster, então"
  echo "o pod fica esperando. Rode ./change-admin-password.sh a partir do seu"
  echo "clone que faz git push (ver README, seção \"Senha do admin\"); o pod"
  echo "sobe sozinho depois disso."
  exit 0
fi
kubectl rollout status deployment/rundeck -n rundeck --timeout=300s

echo ""
echo "Rundeck vai ficar disponível em https://rundeck.diegofnunesbr.com"
echo "assim que cert-manager/ingress-nginx/dns estiverem prontos (ver"
echo "repositório argocd). Até lá, ou pra configurar o projeto agora,"
echo "use port-forward:"
echo ""
echo "  kubectl -n rundeck port-forward svc/rundeck 30440:4440"
echo "  (login admin + senha definida pelo change-admin-password.sh, em http://localhost:30440)"
echo ""
echo "Siga o README.md para configurar o projeto e importar os jobs."
