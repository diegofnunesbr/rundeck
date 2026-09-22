# Rundeck

Rundeck é uma plataforma de automação de operações que permite criar, agendar e executar runbooks (jobs) sobre infraestrutura via SSH/Ansible.

## Pré-requisitos

- Kubernetes (k0s, single-node)
- kubectl, Docker
- **`deploy.sh` precisa rodar direto no node do cluster** (ex.: `vm-ubuntu`),
  não numa máquina remota - os volumes `ansible-playbooks`/`ansible-inventory`
  em `rundeck.yaml` são `hostPath`, ou seja, apontam pro filesystem do node
  onde o pod é agendado, não pra máquina de onde você roda o `deploy.sh`.
- `cert-manager` e `ingress-nginx` instalados (repositório `cert-manager`
  e `core-config` do repositório `argocd`) e DNS `rundeck.diegofnunesbr.com`
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
│   ├── add-ssh-key.yaml
│   ├── remove-ssh-key.yaml
├── keys/                     # Chave SSH (gerada pelo deploy.sh, ignorada pelo git)
├── dockerfile                # Imagem Rundeck + Ansible
├── rundeck.yaml              # Manifests Kubernetes
└── deploy.sh                 # Script de instalação
```

## Instalação

Clone o repositório e ajuste os arquivos abaixo antes de executar:

| Arquivo | O que alterar |
|---|---|
| `inventory/hosts` | IP e usuário dos hosts Ansible |
| `inventory/nodes.yaml` | IP e nome dos nodes visíveis no Rundeck |

```bash
git clone https://github.com/diegofnunesbr/rundeck.git
cd rundeck
./deploy.sh
```

O script faz o build da imagem Docker, gera a chave SSH, cria os recursos no Kubernetes e aguarda o Rundeck inicializar (~2 min). No final exibe o IP para acesso.

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
curl -s -L -c "$COOKIE_JAR" -o /dev/null \
  -d "j_username=admin&j_password=admin" \
  "http://localhost:30440/j_security_check"
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
curl -s -G 'http://<ip-do-node-k0s>:30900/prometheus/api/v1/query' \
  --data-urlencode 'query=up{host="<ip-da-vm>"}'
```

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
