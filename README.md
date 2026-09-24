# Rundeck

Rundeck é uma plataforma de automação de operações que permite criar, agendar e executar runbooks (jobs) sobre infraestrutura via SSH/Ansible.

## Pré-requisitos

- Kubernetes (k0s, single-node)
- kubectl, Docker
- ArgoCD instalado (ver repositório `argocd`)
- **O repo precisa estar clonado em `/home/diegofnunesbr/rundeck` no node
  do cluster** (`vm-ubuntu`), e o `deploy.sh` roda lá - os volumes
  `ansible-playbooks`/`ansible-inventory` em `rundeck.yaml` são `hostPath`
  fixos nesse caminho (o ArgoCD aplica o manifesto como está no git, não
  tem como descobrir onde o repo foi clonado). Mudou o caminho? Ajuste os
  dois `hostPath` em `rundeck.yaml`.
- `cert-manager` e `ingress-nginx` instalados (repositórios
  `cert-manager` e `ingress-nginx`) e DNS `rundeck.diegofnunesbr.com`
  apontando pro node (repositório `dns`) - **não são pré-requisito pra
  rodar `deploy.sh`**, só pra `https://rundeck.diegofnunesbr.com` ficar
  acessível depois. Sem eles, use port-forward (seção "Configuração").

## Estrutura do repositório

```
rundeck/
├── ansible/                  # Playbooks Ansible
│   ├── _stage_target.yml     # registra um host dinamicamente pra um run (onboarding)
│   ├── onboard-vm.yml        # integra VM nova (usa _stage_target.yml e install-alloy.yml)
│   ├── install-alloy.yml     # instala node_exporter + Grafana Alloy (remote_write pro Mimir)
│   ├── templates/
│   │   └── config.alloy.j2
│   ├── add-ssh-key.yml
│   ├── remove-ssh-key.yml
├── docs/                     # runbooks em markdown, um por procedimento
│   └── new-vm-provisioning.md
├── inventory/                # Hosts e nodes do ambiente
│   ├── hosts                 # Inventário Ansible
│   └── nodes.yaml            # Nodes visíveis no Rundeck
├── jobs/                     # Definições de jobs do Rundeck
│   ├── onboard-vm.yaml
│   ├── install-alloy.yaml   # reinstala o Alloy numa VM (ex.: depois de mudar o template)
│   ├── add-ssh-key.yaml
│   ├── remove-ssh-key.yaml
├── keys/                     # Chave SSH (gerada pelo deploy.sh, ignorada pelo git)
├── applications/
│   └── argocd.rundeck.yaml   # Application do Argo CD
├── dockerfile                # Imagem Rundeck + Ansible
├── rundeck.yaml              # Manifests Kubernetes (aplicados pelo Argo CD)
├── rundeck-realm.sealed.yaml # login do admin local (realm.properties selado, fallback, ver "Login pelo Keycloak")
├── rundeck-oidc.sealed.yaml  # client secret + cookie secret do oauth2-proxy (selado, aplicado pelo Argo CD)
├── change-admin-password.sh  # define/troca a senha do admin
└── deploy.sh                 # Bootstrap: imagem local, chave SSH e Application
```

## Senha do admin

O login vem de um `realm.properties` guardado no SealedSecret
`rundeck-realm.sealed.yaml`, montado por cima do arquivo que vem na imagem
(que tem as senhas padrão `admin`/`admin` e `user`/`user`). Só existe o
usuário `admin`. Pra definir (cluster novo, com outra chave do Sealed
Secrets) ou trocar a senha, rode do seu clone que faz `git push`
(precisa de `kubeseal` e do contexto `k0s`, ver README do repositório
`argocd`, seção "Acessar o cluster de fora da VM"):

```bash
./change-admin-password.sh
```

Pede a senha sem ecoar, sela, faz commit + push, espera o Argo CD
sincronizar e reinicia o pod (o arquivo é montado com `subPath`, que não
atualiza sozinho). A senha não pode ter vírgula, nem começar/terminar com
espaço: é o formato do `realm.properties` (`usuario:senha,papel,...`).
A imagem só suporta os formatos de senha básicos do Jetty (texto, `MD5:`,
`CRYPT:`, sem bcrypt), então a senha fica em texto dentro do Secret - o
mesmo nível de proteção das senhas do Jenkins e do Grafana: selada no
git, legível só por quem já é admin do cluster.

## Login pelo Keycloak (SSO)

O Rundeck Open Source não tem OIDC nativo (isso é recurso da versão
Enterprise), então quem faz a autenticação é um sidecar
[`oauth2-proxy`](https://oauth2-proxy.github.io/oauth2-proxy/) no mesmo
pod, na frente do Rundeck. O Rundeck confia no usuário/grupos que vêm
nos headers HTTP do proxy ("modo pré-autenticado", nativo do Rundeck,
sem plugin) - é o mesmo padrão da empresa (`Keycloak.txt`).

```text
Ingress → Service:4180 (oauth2-proxy) → valida com o Keycloak
                                       → injeta X-Forwarded-Preferred-Username
                                         e X-Forwarded-Groups
                                       → localhost:4440 (Rundeck)
```

`rundeck.yaml` configura os dois lados:
- **oauth2-proxy**: `--provider=oidc` apontando pro realm `home`
  (repositório `keycloak`), `--pass-user-headers=true` (manda os headers
  acima pro Rundeck) e `--upstream=http://127.0.0.1:4440/` (fala com o
  Rundeck direto, sem passar pela rede do cluster).
- **Rundeck**: `RUNDECK_PREAUTH_*` (modo pré-autenticado nativo, variáveis
  de ambiente da imagem oficial) lê `X-Forwarded-Preferred-Username` como
  usuário e `X-Forwarded-Groups` como grupos/papéis.

Quem estiver no grupo `rundeck-admins` do Keycloak vira admin: a ACL
`rundeck-admins.aclpolicy` (ConfigMap em `rundeck.yaml`, mesmo conteúdo do
`admin.aclpolicy` que já vem na imagem, só trocando `group: admin` por
`group: rundeck-admins`) dá acesso total pra esse grupo. Ninguém mais
entra (sem grupo, sem acesso a nada).

O client secret do Keycloak e o cookie secret do oauth2-proxy ficam
selados em `rundeck-oidc.sealed.yaml`.

**Sign out** funciona de ponta a ponta: o Rundeck redireciona pro
`/oauth2/sign_out` do proxy (que limpa o cookie) com um `rd=` apontando
pro endpoint de logout do Keycloak (com `id_token_hint`, preenchido
automaticamente pelo oauth2-proxy) - sem isso, o logout só derrubaria a
sessão do Rundeck e o Keycloak logaria de volta sozinho.

**A Service continua expondo a porta `4440` direto** (nome `direct`,
sem passar pelo oauth2-proxy) - é o que os `curl`/`j_security_check` da
seção "Configuração" usam, com o login local (`admin` + senha selada em
`rundeck-realm.sealed.yaml`). Essa porta não é exposta pelo Ingress, só
via port-forward - é o plano B se o Keycloak cair, igual ao Jenkins e ao
Grafana.

Pra dar acesso a alguém: no Keycloak, realm `home`, coloque o usuário no
grupo `rundeck-admins`.

## Instalação

Clone o repositório e ajuste os arquivos abaixo antes de executar:

| Arquivo | O que alterar |
|---|---|
| `inventory/hosts` | IP e usuário dos hosts Ansible |
| `inventory/nodes.yaml` | IP e nome dos nodes visíveis no Rundeck |

```bash
git clone https://github.com/diegofnunesbr/rundeck.git /home/diegofnunesbr/rundeck
cd /home/diegofnunesbr/rundeck
./deploy.sh
```

O script faz o build da imagem Docker e importa no containerd do k0s, gera a
chave SSH e cria o secret `rundeck-ssh-key` (ambos ficam fora do git), e
aplica a Application do Argo CD, que cuida do resto (`rundeck.yaml`). Depois
disso, qualquer mudança em `rundeck.yaml` só tem efeito após `git push`.

## Preparar hosts

VMs criadas pelo repositório `terraform` já nascem prontas (o cloud-init
de lá inclui essa mesma chave automaticamente) - esse passo manual só é
necessário pra hosts que não passaram por aquele fluxo (ex.: uma VM já
existente antes, ou criada manualmente).

Para cada host que o Rundeck vai gerenciar via SSH, instale a chave pública gerada pelo `deploy.sh`. Repita para cada novo host adicionado ao inventário.

Ajuste as variáveis antes de executar:

| Variável | O que alterar |
|---|---|
| `HOST_IP` | IP do host a ser configurado |
| `HOST_ADMIN` | Usuário admin com sudo no host |

```bash
HOST_IP="192.168.0.4"
HOST_ADMIN="diegofnunesbr"

ssh "$HOST_ADMIN@$HOST_IP" "
  id rundeck &>/dev/null || sudo useradd -m -s /bin/bash rundeck
  sudo mkdir -p /home/rundeck/.ssh
  sudo chmod 700 /home/rundeck/.ssh
  echo '$(cat keys/rundeck.pub)' | sudo tee /home/rundeck/.ssh/authorized_keys > /dev/null
  sudo chmod 600 /home/rundeck/.ssh/authorized_keys
  sudo chown -R rundeck:rundeck /home/rundeck/.ssh
"
```

## Configuração

O Service é `ClusterIP` (sem NodePort) - use port-forward pra rodar os
comandos abaixo, numa aba de terminal separada:

```bash
kubectl -n rundeck port-forward svc/rundeck 30440:4440
```

# 1. Configurar o projeto via API
```bash
API="http://localhost:30440/api/14"
COOKIE_JAR=$(mktemp)
read -rsp "Senha do admin do Rundeck: " RD_PW; echo
printf '%s' "$RD_PW" | curl -s -L -c "$COOKIE_JAR" -o /dev/null \
  -d "j_username=admin" --data-urlencode "j_password@-" \
  "http://localhost:30440/j_security_check"
unset RD_PW
```

# 2. Criar projeto
```bash
curl -s -b "$COOKIE_JAR" -X POST -H "Content-Type: application/json" \
  -d '{"name":"foundation"}' "$API/projects"
```

# 3. Configurar node source, globals e autenticação SSH
```bash
CONFIG='{"project.name":"foundation","globals.ansible_dir":"/home/rundeck/ansible","resources.source.1.type":"file","resources.source.1.config.file":"/home/rundeck/inventory/nodes.yaml","resources.source.1.config.format":"resourceyaml","resources.source.1.config.generateFileAutomatically":"false","resources.source.1.config.includeServerNode":"true","project.ssh-authentication":"privateKey","project.ssh-key-storage-path":"keys/project/foundation/ssh-key","project.ssh-user":"rundeck"}'
curl -s -b "$COOKIE_JAR" -X PUT -H "Content-Type: application/json" \
  -d "$CONFIG" "$API/project/foundation/config"
```

As três chaves `project.ssh-*` são pro **executor SSH nativo** do Rundeck
(usado pelos comandos ad-hoc em "Commands" e por qualquer job que não seja
`AnsiblePlaybookWorkflowStep`) - sem elas, esses comandos falham com
`Unknown: /home/rundeck/.ssh/id_rsa (No such file or directory)`, mesmo
com os jobs de Ansible funcionando normalmente (o plugin Ansible tem sua
própria config de chave, `ansible-ssh-key-storage-path`, independente
dessa).

**Atenção:** `PUT .../config` substitui o arquivo de config inteiro, não
faz merge. Se for atualizar só uma propriedade depois (ex.: adicionar essa
config de SSH numa instalação já existente), busque a config atual com
`GET .../config` primeiro e reenvie **todas** as chaves - um `PUT` parcial
apaga o resto (aconteceu no onboarding do observability: um PUT só com as
chaves `ssh-*` zerou o `resources.source` e sumiu com os nodes).

# 4. Adicionar chave SSH ao Key Storage
```bash
curl -s -b "$COOKIE_JAR" -X POST \
  -H "Content-Type: application/octet-stream" -H "X-Rundeck-Data-Type: private" \
  --data-binary @keys/rundeck "$API/storage/keys/project/foundation/ssh-key"
```

# 5. Importar jobs
```bash
for job in jobs/*.yaml; do
  curl -s -b "$COOKIE_JAR" -X POST -H "Content-Type: application/yaml" \
    --data-binary @"$job" \
    "$API/project/foundation/jobs/import?fileformat=yaml&uuidOption=preserve&dupeOption=update"
done

rm -f "$COOKIE_JAR"
```

## Integrar uma VM nova

Ver [`docs/new-vm-provisioning.md`](docs/new-vm-provisioning.md) - fluxo
completo desde o `terraform apply` até a VM integrada via job
`onboard-vm`, sem precisar cadastrar ela no inventário antes.

O job também: (1) grava a VM em `inventory/nodes.yaml` e `inventory/hosts`
de forma permanente (não só pra aquele run), e (2) instala `node_exporter`
+ Grafana Alloy configurado com `remote_write` pro Mimir do homelab (ver
repositório `mimir`) - a VM aparece com métricas no Grafana logo após o
onboarding, sem passo manual.

## Verificar o onboarding

```bash
ssh rundeck@<ip-da-vm> "systemctl is-active prometheus-node-exporter alloy"
kubectl --context=k0s -n mimir port-forward svc/mimir 8080:8080 &
curl -s -G 'http://localhost:8080/prometheus/api/v1/query' \
  --data-urlencode 'query=up{host="<ip-da-vm>"}'
```

Também dá pra consultar direto pelo domínio, que é aberto:
`https://mimir.diegofnunesbr.com/prometheus/api/v1/query`.

## Troubleshooting: "Permission denied (publickey,password)" no onboard-vm

Se o job falhar com esse erro mesmo com a VM alcançável, a causa mais
comum é a chave pública em `/home/rundeck/.ssh/authorized_keys` da VM
estar desatualizada em relação à `keys/rundeck.pub` atual (acontece se
`keys/` foi regenerada em algum momento sem reinstalar a chave em todo
mundo). Corrija reinstalando a chave certa na VM e reenviando a privada
pro Key Storage do Rundeck:

```bash
ssh "$HOST_ADMIN@$HOST_IP" "
  sudo sh -c 'cat > /home/rundeck/.ssh/authorized_keys' < keys/rundeck.pub
  sudo chown rundeck:rundeck /home/rundeck/.ssh/authorized_keys
  sudo chmod 600 /home/rundeck/.ssh/authorized_keys
"

curl -s -b "$COOKIE_JAR" -X PUT \
  -H "Content-Type: application/octet-stream" -H "X-Rundeck-Data-Type: private" \
  --data-binary @keys/rundeck "$API/storage/keys/project/foundation/ssh-key"
```

## Remoção

```bash
kubectl delete namespace rundeck
```

Remove todos os recursos, incluindo dados persistidos.
