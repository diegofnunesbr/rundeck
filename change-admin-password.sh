#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CTX="${KUBE_CONTEXT:-k0s}"
K="kubectl --context=$CTX"
SEALED=rundeck-realm.sealed.yaml
$K -n rundeck get deploy rundeck >/dev/null || { echo "Sem acesso ao Rundeck pelo contexto '$CTX' (ver README do repositório argocd, seção do kubeconfig)."; exit 1; }

read -rsp "Nova senha do admin do Rundeck: " PW; echo
read -rsp "Confirme a senha: " PW2; echo
[ -n "$PW" ] && [ "$PW" = "$PW2" ] || { echo "Senhas vazias ou diferentes."; exit 1; }
[[ "$PW" != *,* ]] || { echo "A senha não pode ter vírgula (é o separador do realm.properties)."; exit 1; }
[[ "$PW" == "${PW#[[:space:]]}" && "$PW" == "${PW%[[:space:]]}" ]] || { echo "A senha não pode começar nem terminar com espaço."; exit 1; }
[[ ! "$PW" =~ ^(OBF|MD5|CRYPT): ]] || { echo "A senha não pode começar com OBF:, MD5: ou CRYPT: (o Rundeck interpretaria como hash)."; exit 1; }

git pull --ff-only

cat <<EOF | kubeseal --context "$CTX" --controller-name sealed-secrets --controller-namespace kube-system \
  --scope cluster-wide --format yaml > "$SEALED"
apiVersion: v1
kind: Secret
metadata:
  name: rundeck-realm
  namespace: rundeck
type: Opaque
data:
  realm.properties: $(printf 'admin:%s,user,admin\n' "$PW" | base64 -w0)
EOF

git add "$SEALED"
git commit -m "rotate rundeck admin password"
git push

REV=$(git rev-parse HEAD)
$K -n argocd annotate application rundeck argocd.argoproj.io/refresh=hard --overwrite >/dev/null
echo "Aguardando o Argo CD sincronizar $REV..."
STATUS=""
for _ in $(seq 1 60); do
  STATUS=$($K -n argocd get application rundeck -o jsonpath='{.status.sync.status} {.status.sync.revision}')
  [[ "$STATUS" == "Synced $REV" ]] && break
  sleep 5
done
[[ "$STATUS" == "Synced $REV" ]] || { echo "Timeout esperando o sync. Rode o restart manualmente depois."; exit 1; }

sleep 5
$K -n rundeck rollout restart deployment/rundeck
$K -n rundeck rollout status deployment/rundeck --timeout=600s
echo "Pronto. Login: admin + senha nova em https://rundeck.diegofnunesbr.com"
