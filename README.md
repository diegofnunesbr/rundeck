# Rundeck

Rundeck é uma plataforma de automação de operações que permite criar, agendar e executar runbooks (jobs) sobre infraestrutura via SSH/Ansible.

## Pré-requisitos

- Kubernetes
- kubectl
- Docker

## Estrutura do repositório

```
rundeck/
├── ansible/                  # Playbooks Ansible
│   ├── add-ssh-key.yml
│   ├── remove-ssh-key.yml
├── inventory/                # Hosts e nodes do ambiente
│   ├── hosts                 # Inventário Ansible
│   └── nodes.yaml            # Nodes visíveis no Rundeck
├── jobs/                     # Definições de jobs do Rundeck
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

# 1. Configurar o projeto via API
```bash
RUNDECK_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
API="http://$RUNDECK_IP:30440/api/14"
COOKIE_JAR=$(mktemp)
curl -s -L -c "$COOKIE_JAR" -o /dev/null \
  -d "j_username=admin&j_password=admin" \
  "http://$RUNDECK_IP:30440/j_security_check"
```

# 2. Criar projeto
```bash
curl -s -b "$COOKIE_JAR" -X POST -H "Content-Type: application/json" \
  -d '{"name":"foundation"}' "$API/projects"
```

# 3. Configurar node source e globals
```bash
CONFIG='{"project.name":"foundation","globals.ansible_dir":"/home/rundeck/ansible","resources.source.1.type":"file","resources.source.1.config.file":"/home/rundeck/inventory/nodes.yaml","resources.source.1.config.format":"resourceyaml","resources.source.1.config.generateFileAutomatically":"false","resources.source.1.config.includeServerNode":"true"}'
curl -s -b "$COOKIE_JAR" -X PUT -H "Content-Type: application/json" \
  -d "$CONFIG" "$API/project/foundation/config"
```

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

## Remoção

```bash
kubectl delete namespace rundeck
```

Remove todos os recursos, incluindo dados persistidos.
