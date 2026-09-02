# UFTM-Proxmox-Casas

[![proxmox](https://img.shields.io/badge/proxmox-Proxmox-0072C6?style=flat-square&logo=proxmox&logoColor=white)](https://github.com/topics/proxmox) [![opnsense](https://img.shields.io/badge/opnsense-OPNsense-F7931E?style=flat-square&logo=opnsense&logoColor=white)](https://github.com/topics/opnsense) [![evpn](https://img.shields.io/badge/evpn-EVPN-4C6EF5?style=flat-square&logo=network-wired&logoColor=white)](https://github.com/search?q=evpn&type=repositories) [![wireguard](https://img.shields.io/badge/wireguard-WireGuard-2CA01C?style=flat-square&logo=wireguard&logoColor=white)](https://github.com/topics/wireguard) [![brasil](https://img.shields.io/badge/brasil-Brasil-FFCC00?style=flat-square&logo=globe-americas&logoColor=white)](https://github.com/search?q=brasil&type=repositories) [![universidade-federal](https://img.shields.io/badge/universidade--federal-Universidade--Federal-6f42c1?style=flat-square&logo=university&logoColor=white)](https://github.com/search?q=%22universidade+federal%22&type=repositories)

Automação de instalação e configuração de rede overlay (WireGuard Fabric +
EVPN/VXLAN) para os hosts Proxmox VE 9 da UFTM (matriz e filiais/"casas").

## O que este repositório faz

Ao rodar em um host Proxmox VE 9 novo, o script principal:

1. Executa a rotina de pós-instalação padrão do Proxmox (fontes deb822,
   remoção do aviso de assinatura, repositório no-subscription) — adaptada
   de [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE).
2. Cria a estrutura de SDN do site (Fabric WireGuard, controller EVPN, zone
   EVPN, VNets das VLANs propagadas, zone/vnet/subnet de SNAT), usando os
   dados do host selecionado em uma planilha CSV.
3. Opcionalmente instala a VM OPNsense do site, quando aplicável.

## Uso rápido

Em um host Proxmox VE 9 novo (via SSH, como root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GlGontijo/UFTM-Proxmox-Casas/main/bootstrap.sh)
```

Isso clona o repositório em `/opt/uftm-proxmox` (ou atualiza, se já existir)
e executa `setup.sh`.

Para fixar uma versão/tag específica em vez do branch `main`:

```bash
UFTM_BRANCH=v1.0 bash <(curl -fsSL https://raw.githubusercontent.com/GlGontijo/UFTM-Proxmox-Casas/main/bootstrap.sh)
```

## Estrutura do repositório

```
.
├── bootstrap.sh                  # ponto de entrada remoto (clone + executa setup.sh)
├── setup.sh                      # orquestrador principal (menu, chama os scripts em bin/)
├── bin/
│   ├── post-pve-install.sh       # pós-instalação Proxmox (fontes, nag, update)
│   ├── install-sdn-zone.sh       # cria a estrutura SDN a partir do hosts.csv
│   └── install_vm_opnsense.sh    # instala a VM OPNsense (quando aplicável)
├── data/
│   └── hosts.csv.example         # modelo do CSV -- copie para hosts.csv e preencha
├── LICENSE
└── .gitignore
```

> **`setup.sh` ainda não foi escrito neste repositório de exemplo.** Ele é o
> orquestrador que apresenta o menu inicial, executa `post-pve-install.sh`,
> depois `install-sdn-zone.sh` e, se aplicável, `install_vm_opnsense.sh`.

## Formato do `data/hosts.csv`

Delimitador `;`, com cabeçalho. **Este arquivo contém dados sensíveis (IPs
WAN, endpoints WireGuard, chaves privadas) e nunca deve ser commitado** — ele
está no `.gitignore`. Copie o exemplo antes de preencher:

```bash
cp data/hosts.csv.example data/hosts.csv
```

| Coluna         | Descrição                                              |
|----------------|---------------------------------------------------------|
| `Host`         | Hostname do Proxmox (deve bater com o hostname real)     |
| `IP_WAN`       | IP público do site                                       |
| `WG_Endpoint`  | `IP:porta` do endpoint WireGuard deste site               |
| `WG_PK`        | Chave privada WireGuard do site (ver nota abaixo)         |
| `WG_TunnelIP`  | IP do túnel WireGuard (rede `10.255.255.0/24`)            |
| `OPNsense`     | `s` para instalar a VM OPNsense neste site, `n` caso contrário |

Durante a execução do `install-sdn-zone.sh`, também é possível escolher a
opção **"Configuração avançada (manual)"** no menu para informar os dados na
hora, em vez de usar uma linha do CSV — nesse modo o script pode gerar um
novo par de chaves WireGuard (`wg genkey`) automaticamente.

> **Nota sobre `WG_PK`:** a API de SDN Fabrics do Proxmox (recurso novo,
> introduzido no PVE 9.2) não expõe um parâmetro de chave privada na criação
> do fabric node — o Proxmox gera e guarda a chave internamente
> (provavelmente em `/etc/pve/priv/wg-keys.cfg`). Por isso, hoje, o valor de
> `WG_PK` **não é aplicado automaticamente**; o script apenas avisa que uma
> chave foi informada mas não pôde ser injetada, e você pode conferir a
> chave pública gerada com:
> ```bash
> pvesh get /cluster/sdn/fabrics/node/WG-FAB/<hostname>
> ```
> Esse comportamento deve ser revisado assim que o formato de
> `/etc/pve/priv/wg-keys.cfg` for confirmado em um host de teste.

## Variáveis fixas do projeto

Editáveis no topo de `bin/install-sdn-zone.sh`:

- Hub WireGuard (`HUB_NODE_ID`, `HUB_ENDPOINT`, `HUB_PUBKEY`, `HUB_TUNNEL_IP`)
- ASN EVPN (`EVPN_ASN`, padrão `65000`)
- VRF-VXLAN da zone EVPN (`EVPN_VRF_VXLAN`, padrão `100`)
- MTU (`EVPN_MTU`, padrão `1360` — necessário por causa da pilha
  WireGuard + PPPoE + VXLAN)
- Lista de VLANs propagadas (`VLANS`, mesma em todos os sites)
- Rede/gateway de SNAT (`SNAT_SUBNET`, `SNAT_GATEWAY`)

## Idempotência

Os scripts verificam se cada objeto SDN (fabric, node, controller, zone,
vnet, subnet) já existe antes de criar. Se existir, perguntam se deve
**sobrescrever** (apaga e recria) ou manter como está.

## Validação recomendada antes de produção

A seção de **SDN Fabric (WireGuard)** em `install-sdn-zone.sh` usa uma API
muito recente do Proxmox (introduzida no 9.2) e ainda tem pontos marcados
com `# VALIDAR` no código. Antes de rodar em um site de produção, valide em
`pve-testes-gontijo` e compare a saída de `/etc/pve/sdn/*.cfg` com a de um
site já configurado corretamente.

## Licença

MIT — ver [LICENSE](./LICENSE). O arquivo `bin/post-pve-install.sh` é
derivado do projeto
[community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
(também MIT), com atribuição preservada no cabeçalho do próprio arquivo.
