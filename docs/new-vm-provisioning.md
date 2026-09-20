# Provisionar uma VM nova

Fluxo completo, do zero até a VM integrada ao Rundeck.

## 1. Criar a VM (Terraform)

No repositório `terraform`:

```bash
cd proxmox/homelab/vm-test
terragrunt apply
```

Isso sobe a VM no Proxmox, já injetando o cloud-init do repositório
`cloud-init` (usuário, chave SSH, pacotes básicos).

## 2. Integrar ao Rundeck (job onboard-vm)

Assim que a VM terminar de subir (o cloud-init já rodou), dispare o job
`onboard-vm`, passando o IP dela:

- Project: `foundation`
- Job: `onboard-vm`
- Option `target_hosts`: IP da VM nova (ex.: `192.168.0.10`)

O job registra a VM dinamicamente pra esse run (não precisa cadastrar no
inventário antes) e aplica a configuração básica.

## 3. Cadastrar no inventário permanente (opcional)

Se a VM for ficar por um bom tempo, adicione ela em
`inventory/nodes.yaml` (visível como node no Rundeck) e no
`ansible/homelab-inventory/inventory.ini` do repositório `ansible` (pra
comandos ad hoc futuros não precisarem do `target_hosts` de novo).

## Troubleshooting

- Job falha com erro de SSH: confirme que a chave pública do Rundeck
  (`keys/rundeck.pub`) está autorizada na VM - o cloud-init já devia ter
  feito isso, se o usuário/chave no template de cloud-init baterem com o
  usuário/chave usados aqui.
- `target_hosts` não reconhecido: confirme que passou o IP exato (sem
  espaços/protocolo), igual aparece no output do `terragrunt apply`.
