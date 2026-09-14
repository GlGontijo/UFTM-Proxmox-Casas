# UFTM-Proxmox-Casas

[![proxmox](https://img.shields.io/badge/ProxmoxVE-9.2-0072C6?style=flat-square&logo=proxmox&logoColor=white)](https://github.com/topics/proxmox) [![opnsense](https://img.shields.io/badge/OPNsense-26.7-F7931E?style=flat-square&logo=opnsense&logoColor=white)](https://github.com/topics/opnsense) [![evpn](https://img.shields.io/badge/EVPN-VxLAN-4C6EF5?style=flat-square&logo=network-wired&logoColor=white)](https://github.com/search?q=evpn&type=repositories) [![wireguard](https://img.shields.io/badge/WireGuard-VPN-2CA01C?style=flat-square&logo=wireguard&logoColor=white)](https://github.com/topics/wireguard) [![universidade-federal](https://img.shields.io/badge/UFTM-Universidade--Federal-6f42c1?style=flat-square&logo=university&logoColor=white)](https://github.com/search?q=%22universidade+federal%22&type=repositories) [![brasil](https://img.shields.io/badge/🇧🇷_Brasil-FFCC00?style=flat-square&logo=globe-americas&logoColor=white)](https://github.com/search?q=brasil&type=repositories)

Automação completa de instalação e configuração de rede overlay (WireGuard
Fabric + EVPN/VXLAN) para os hosts Proxmox VE 9 da UFTM (matriz e
filiais/"casas").

## Visão geral

O processo tem duas fases:

1. **`bootstrap.sh`** — prepara a base do Proxmox: valida a versão (só
   9.0–9.2.x é suportada), corrige repositórios (deb822, remove
   `*-enterprise`, habilita `no-subscription`), remove o aviso de assinatura
   na Web UI, faz `dist-upgrade` completo, ajusta timezone
   (`America/Sao_Paulo`) e o `rrdcached` (menos I/O em disco). Depois clona
   (ou atualiza, se já existir) este repositório em `/opt/uftm-proxmox-casas`
   e executa `setup.sh`.
2. **`setup.sh`** — orquestra as 8 etapas de parametrização do site
   (wizard, rede, SDN, VM OPNsense, firewall), descritas abaixo.

## Uso rápido

Em um host Proxmox VE 9 novo (via SSH, como root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/GlGontijo/UFTM-Proxmox-Casas/main/bootstrap.sh)"
```

Isso roda o `bootstrap.sh` descrito acima e, no final, executa
`/opt/uftm-proxmox-casas/setup.sh` automaticamente.

Se o repositório já estiver clonado localmente:

```bash
./bootstrap.sh
# ou pular direto pro orquestrador (pula a preparação do host):
./setup.sh [-c /caminho/para/hosts.csv]
```

A flag `-c` (repassada por `bootstrap.sh` via `"$@"`) permite apontar para um
`hosts.csv` em outro caminho, caso não queira usar `data/hosts.csv`.

## As 8 etapas do `setup.sh`

O `pve-firewall` fica **desligado durante todo o processo** (etapa 0) e só
volta a ligar no final da etapa 7, depois que todas as regras já foram
escritas de uma vez.

| # | Script | O que faz |
|---|--------|-----------|
| 1 | `bin/wizard.sh` | Único ponto de perguntas do projeto — resumível (cada resposta é gravada assim que é dada). Escolhe o host (via `hosts.csv` ou manual), a chave privada WireGuard, o número de patrimônio, a rede (WAN/LAN/console), as VLANs a propagar, os parâmetros da VM OPNsense e as faixas de IP WAN autorizadas no firewall. Nenhum outro script pergunta nada — todos leem o estado gravado aqui. |
| 2 | `bin/download-deps.sh` | Todo `apt-get install` do projeto (SDN/FRR/WireGuard/PPPoE/SNMP/Syslog/`expect`/etc), download da imagem `nano` do OPNsense e do backup `config.xml` (se aplicável) — tudo enquanto a internet do laboratório ainda funciona. |
| 3 | `bin/network-install.sh` | Reescreve `/etc/network/interfaces` de forma determinística e completa (WAN em DHCP/fixo/PPPoE, LAN trunk, console opcional). A partir daqui a internet do laboratório pode cair de propósito. |
| 4 | `bin/hostname-and-restart.sh` | Aplica o hostname final (`<base>-<patrimônio>`), grava o IP de gerência e o domínio local em `/etc/hosts`, reinicia rede e serviços do Proxmox. |
| 5 | `bin/sdn-install.sh` + `bin/evpn-bind-vlan.sh` | Cria via `pvesh` o fabric WireGuard, o controller EVPN, a zone EVPN/VXLAN, os vnets das VLANs selecionadas e a zone/vnet/subnet de SNAT. Em seguida, instala um serviço systemd persistente (`ip monitor link`) que mantém as sub-interfaces 802.1Q da bridge de trunk escravizadas aos vnets correspondentes, sobrevivendo a `ifreload` e à recriação dos dispositivos. |
| 6 | `bin/opnsense-vm.sh` | Cria a VM OPNsense (imagem `nano`, já em cache) e automatiza o wizard inicial via console serial (atribuição de interfaces `vtnet0`=WAN/`vtnet1`=LAN). Se houver `config.xml` de backup, aplica o MSS clamping (1320) e o entrega via um servidor HTTP efêmero na bridge de SNAT, buscado de dentro do próprio OPNsense. |
| 7 | `bin/pve-firewall-config.sh` | Configura SNMP, encaminhamento de Syslog remoto e as regras de firewall (`ipset` com os IPs WAN autorizados coletados no wizard) e só então religa o `pve-firewall`. |
| 8 | (dentro do próprio `setup.sh`) | Resumo final e pergunta se deseja reiniciar agora para validar o boot completo (rede, SDN, VM, firewall). |

## Estrutura do repositório

```
.
├── bootstrap.sh                    # ponto de entrada remoto (prepara o host + clona/atualiza + executa setup.sh)
├── setup.sh                        # orquestrador das 8 etapas
├── bin/
│   ├── wizard.sh                   # etapa 1 — questionário único e resumível
│   ├── download-deps.sh            # etapa 2 — apt-get + downloads (com internet)
│   ├── network-install.sh          # etapa 3 — grava a rede final
│   ├── hostname-and-restart.sh     # etapa 4 — hostname + restart de rede/Proxmox
│   ├── sdn-install.sh              # etapa 5 — fabric WireGuard + EVPN + vnets + SNAT
│   ├── evpn-bind-vlan.sh           # etapa 5 — bind persistente das VLANs de trunk
│   ├── opnsense-vm.sh              # etapa 6 — VM OPNsense
│   └── pve-firewall-config.sh      # etapa 7 — SNMP/Syslog/regras + liga o firewall
├── lib/
│   └── common.sh                   # funções compartilhadas (msg_*, state_*, validações)
├── data/
│   ├── hosts.csv.example           # modelo do CSV
│   └── hosts.csv                   # dados reais (git-ignored, copie do .example)
├── var/log/                        # gerado em runtime (git-ignored) — logs contínuos, ex. pvesh.log
├── LICENSE
├── .gitattributes
└── .gitignore
```

## Formato do `data/hosts.csv`

Delimitador `;`, com cabeçalho, 5 colunas:

```
Host;WG_Port;WG_TunnelIP;OPNsense;URL_BKPRepo
```

| Coluna | Descrição |
|--------|-----------|
| `Host` | Hostname base do Proxmox, sem o número de patrimônio (ex: `pve-odonto`) |
| `WG_Port` | Porta do túnel WireGuard deste site |
| `WG_TunnelIP` | IP do túnel WireGuard (rede `10.255.255.0/24`) |
| `OPNsense` | `s` para instalar a VM OPNsense neste site, `n` caso contrário |
| `URL_BKPRepo` | URL/pasta do backup do `config.xml` (vazio = instalação limpa) |

Copie o exemplo antes de preencher:

```bash
cp data/hosts.csv.example data/hosts.csv
```

No wizard também é possível escolher **"Configuração avançada (manual)"**
para informar os mesmos dados na hora, em vez de usar uma linha do CSV.

> **O que fica fora do CSV (e do Git) de propósito:** a chave privada
> WireGuard, o IP/modo da WAN (DHCP, fixo ou PPPoE), os parâmetros da VM
> OPNsense (storage, vCPU, RAM, disco, versão) e as faixas de IP WAN
> autorizadas no firewall são todos coletados interativamente pelo
> `wizard.sh` e gravados só no estado local do host
> (`/etc/uftm-proxmox-casas/wizard-state.env`, `chmod 600`) — nunca em
> nenhum arquivo versionado neste repositório.

## Chave privada WireGuard (fabric)

No wizard, escolha entre informar uma chave existente ou gerar um novo par
(`wg genkey`). A chave privada só fica no estado local do host e não é
exibida novamente depois de gerada.

A API de SDN Fabrics do Proxmox (recurso novo, introduzido no PVE 9.2) ainda
não tem um comportamento totalmente confirmado para aplicar essa chave na
criação do nó do fabric — se `sdn-install.sh` não conseguir aplicá-la
automaticamente, ele avisa na tela. Confira a chave pública já registrada
com:

```bash
pvesh get /cluster/sdn/fabrics/node/WG-FAB/<hostname>
```

## Variáveis fixas do projeto

Editáveis no topo de `bin/sdn-install.sh`:

- Hub WireGuard (`HUB_HOSTNAME`, `HUB_ENDPOINT`, `HUB_PUBKEY`, `HUB_LOOPBACK_IP`)
- ASN EVPN (`EVPN_ASN`, padrão `65000`)
- VRF-VXLAN da zone EVPN (`EVPN_VRF_VXLAN`, padrão `100`)
- MTU da zone EVPN (`EVPN_ZONE_MTU`, padrão `1360` — necessário por causa da
  pilha WireGuard + PPPoE + VXLAN)
- Rede/gateway de SNAT (`SNAT_SUBNET_CIDR`, `SNAT_GATEWAY`)

A lista padrão de VLANs propagadas (`1010`, `1011`, `1012`, `1022`, `1054`,
`1630`) fica em `bin/wizard.sh` (`DEFAULT_VLANS`) e pode ser complementada
por site direto no próprio wizard.

## Idempotência e retomada

- Todo objeto SDN (fabric, nó, controller, zone, vnet, subnet) é checado via
  `pvesh get` antes de ser criado.
- O wizard é resumível: interromper o processo e rodar `./setup.sh` de novo
  detecta o estado parcial e oferece continuar de onde parou (ou refazer do
  zero).
- O `pve-firewall` fica desligado durante toda a instalação, evitando ficar
  com regras parciais no meio do processo.

## Logs

`sdn-install.sh` grava um log contínuo (sempre em modo *append*, nunca
sobrescrito) de todas as chamadas `pvesh` em `var/log/pvesh.log`, dentro do
próprio clone do repositório — sobrevive a reboots e a atualizações do
repositório (`bootstrap.sh` usa `git reset --hard`, que não mexe em
arquivos não versionados). Se algum objeto do SDN falhar ao ser criado, o
próprio script já imprime o trecho relevante do log na tela; para o
histórico completo de uma instalação, consulte esse arquivo.

## Validação recomendada antes de produção

A seção de fabric WireGuard em `bin/sdn-install.sh` usa uma API muito
recente do Proxmox (introduzida no 9.2). Antes de rodar em um site de
produção, valide em `pve-testes-gontijo` e compare a saída de
`/etc/pve/sdn/*.cfg` com a de um site já configurado corretamente.

## Licença

MIT — ver [LICENSE](./LICENSE).
