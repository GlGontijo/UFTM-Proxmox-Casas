# Extensão de L2 para as "casas" da UFTM

> Como o **UFTM-Proxmox-Casas** estende VLANs da matriz até as unidades remotas
> usando **Proxmox VE 9 + WireGuard + BGP-EVPN/VXLAN**, de forma automatizada,
> repetível e gerenciável.

---

## 1. O problema

A UFTM mantém unidades remotas (as "casas") que precisam se comportar, do ponto
de vista de rede, como se estivessem **no mesmo segmento L2** da matriz. Rotear
entre sites (L3) não resolve, porque os equipamentos envolvidos dependem de
comunicação de camada 2 (descoberta por broadcast, endereçamento fixo no mesmo
domínio, protocolos proprietários de fabricantes) ou de acesso direto e
transparente a partir da matriz.

Sem a extensão de L2, cada casa exigiria:

- deslocamento de técnicos para coleta manual de dados;
- ramais telefônicos remotos com custo recorrente elevado;
- ilhas de monitoramento e CFTV desconectadas da central;
- acesso à gerência dos equipamentos apenas presencial.

## 2. A solução em uma frase

Cada casa recebe **um host Proxmox VE** que forma, junto com um **hub central**, uma malha **WireGuard** (criptografada). Sobre essa malha roda **BGP-EVPN** como plano de controle e **VXLAN** como plano de dados, transportando as VLANs selecionadas de forma transparente entre a casa e a matriz. 

Uma **VM OPNsense** local cuida do roteamento/firewall da unidade. Mas isso será detalhado mais adiante, em outros documentos.

## 3. VLANs estendidas

|  VLAN  | Finalidade | Benefício para a UFTM |
|---------|-----------|-----------------------|
|  **1010**  | Gerencial | Monitoramento e acesso aos equipamentos de rede da casa, a partir da matriz, como se estivessem no mesmo segmento. |
|  **1011**  | Telefonia (ATA / VoIP) | Interliga a telefonia VoIP ao PBX central, **eliminando o alto custo de ramais remotos**. |
|  **1012**  | Câmeras e monitoramento | Permite a **sincronia do CFTV** com a central na matriz. |
|  **1054**  | Registro de ponto | Permite **sincronia remota**, **sem necessidade de ir ao local "baixar os dados" manualmente**. |

### Governança para novas VLANs

Qualquer VLAN além das listadas acima **pode ser incluída posteriormente**, desde que **previamente autorizada e justificada no DIT - ProTIC**. A extensão de L2 aumenta o domínio de broadcast e a superfície de falha; por isso a
inclusão de novas VLANs é uma decisão de governança, não apenas técnica.

## 4. Arquitetura
 
```text
+---------------------------------------------------+
| MATRIZ                                            |
|                                                   |
| Central: PBX, CFTV, servidores de ponto,          |
| monitoramento                                     |
|       |  VLANs 1010 / 1011 / 1012 / 1054          |
| Hub WireGuard + BGP-EVPN (pve-vpnserver)          |
+-------------------------+-------------------------+
                          |
                          |  Tunel WireGuard (UDP) sobre a WAN da casa
                          |  (DHCP / IP fixo / PPPoE)
                          |  EVPN/VXLAN transportado dentro do tunel
                          |
+-------------------------+-------------------------+
| CASA (site remoto)                                |
|                                                   |
| Host Proxmox VE 9 (SDN: fabric WG + EVPN/VXLAN)   |
|    +-- VM OPNsense (firewall/gateway local)       |
|    |                                              |
|    | trunk 802.1Q                                 |
|    |                                              |
| Switch da casa                                    |
|    |                                              |
| ATAs / Cameras / Relogios de ponto / Gerencia     |
+---------------------------------------------------+
```

### Camadas

| Camada | Tecnologia | Papel |
|--------|-----------|-------|
| Transporte | **WireGuard** (Proxmox SDN *Fabrics*, PVE 9.2) | Túnel criptografado hub-and-spoke pela WAN da casa. Rede de túnel `10.255.255.0/24`. |
| Plano de controle | **BGP-EVPN** (FRR, ASN 65000) | Distribui a localização dos MACs/IPs entre os sites, sem depender de flood-and-learn. |
| Plano de dados | **VXLAN** (zone EVPN, VRF-VXLAN 100) | Encapsula os quadros L2 de cada VLAN em UDP dentro do túnel. |
| Plataforma | **Proxmox VE 9** (Debian 13) + SDN | Host da casa; fornece GUI, API e integração de rede/VMs. |
| Firewall local | **OPNsense** (VM, imagem `nano`) | Roteamento, firewall e serviços locais da unidade. |
| Segurança do host | **pve-firewall** + `ipset` | Só as faixas WAN autorizadas da UFTM acessam SSH, 8006, WireGuard e SNMP. |
| Observabilidade | **SNMP** + **Syslog** remoto | Monitoramento e coleta central de logs. |
| Automação | Bash, `whiptail`, `pvesh`, `expect`, systemd | Instalação padronizada e resumível de cada casa. |

### Como uma VLAN chega à casa

1. O **switch da casa** entrega as VLANs em **trunk 802.1Q** a uma NIC do host Proxmox.
2. Essa NIC pertence a uma **bridge vlan-aware** (`bridge-vids 2-4094`).
3. Para cada VLAN selecionada, o SDN cria um **vnet** (`vnet1010`, `vnet1011`,
   `vnet1012`, `vnet1054`) na zone EVPN, com o `tag` da VLAN.
4. O vnet EVPN é uma bridge Linux **sem uplink físico**. Um serviço systemd
   (`uftm-evpn-bind-vlan`) cria a sub-interface `bridge.VLAN` (ex.: `vmbr2.1010`)
   e a **escraviza ao vnet correspondente**, ligando o mundo físico ao fabric VXLAN.
5. Do outro lado, o hub/matriz recebe o mesmo tráfego na VLAN equivalente e o
   equipamento remoto passa a estar, logicamente, no mesmo segmento L2.

## 5. Vias avaliadas

Antes de chegar a esta arquitetura, foram consideradas alternativas. O
critério comum: **estender L2 com plano de controle, manter uma interface de
gerência e não gerar custos de licenciamento por site.**

| Alternativa | Por que não foi adotada |
|-------------|------------------------|
| **Somente VXLAN** (sem EVPN) | Sem plano de controle: o aprendizado de MACs fica em flood-and-learn ou em tabelas estáticas. Em uma topologia hub-and-spoke sobre WAN, o tráfego BUM (broadcast, unknown unicast, multicast) é replicado e a manutenção manual de peers não escala com o número de casas. O EVPN resolve isso distribuindo MACs/IPs via BGP. |
| **OPNsense como VTEP/EVPN** | O OPNsense é baseado em **FreeBSD** e **não implementa EVPN**. Ele continua no projeto, mas como firewall/gateway local, não como participante do fabric. |
| **MikroTik (RouterOS)** | Possui VXLAN, mas depende de **licenciamento** e de recursos específicos por nível/modelo, o que gera custo e heterogeneidade em cada casa. |
| **Linux "puro"** (bridge + VXLAN + FRR direto) | Tecnicamente viável, mas **sem interface gerencial**: sem GUI/API para VMs, rede, firewall, SDN e monitoramento. Aumenta a carga operacional e o risco de erro. |
| **Proxmox VE + SDN (escolhida)** | Reúne EVPN/VXLAN nativos (FRR), fabric WireGuard, GUI/API, virtualização da VM OPNsense e firewall integrado, sem licenciamento por site, e permite automatizar tudo por `pvesh`. |

## 6. Decisões técnicas relevantes

### MTU e MSS

A pilha **PPPoE (MTU 1492) + WireGuard + VXLAN** consome bytes de cabeçalho
em cada camada. Por isso:

- a zone EVPN usa **MTU 1360** (margem conservadora);
- as sub-interfaces 802.1Q das VLANs também usam **MTU 1360**;
- no OPNsense restaurado de backup é aplicado **MSS clamping 1320** (1360 − 40),
  evitando fragmentação e travamentos em HTTP/monitoramento.

### Conectividade WAN da casa

O wizard suporta **DHCP**, **IP fixo** e **PPPoE**. Para PPPoE:

- `pppoe0` fica em arquivo exclusivo (`/etc/network/interfaces.d/pppoe0`);
- um hook aguarda a bridge de uplink antes de subir o `pppoe0`;
- quando o `pppoe0` sobe, o `wg0` é reiniciado, pois o IP/endpoint pode ter mudado;
- um timer re-resolve o DNS do endpoint do hub periodicamente.

### Persistência dos binds VLAN ↔ vnet

Dois comportamentos exigem um serviço dedicado, e não apenas linhas em
`/etc/network/interfaces`:

- o **ifupdown2** reconcilia os membros das bridges a cada `ifreload`,
  desfazendo binds feitos fora do config declarado;
- os dispositivos `vnetXXXX` só existem depois que o **FRR/zebra** sobe, ou seja,
  **depois** do `networking.service`.

O serviço `uftm-evpn-bind-vlan` usa `ip monitor link` (sem polling), filtra
apenas eventos das interfaces relevantes e, a cada reconciliação, garante também
a entrada de VID `self` na bridge trunk. Sem ela, o broadcast (ARP request)
passa, mas o unicast de volta (ARP reply) é descartado.

### Segurança

- Túnel **WireGuard** criptografado ponta a ponta entre casa e hub.
- **pve-firewall** ligado apenas ao final da instalação, com regras escritas de
  uma vez; acesso restrito às faixas WAN autorizadas da UFTM.
- Dados sensíveis (chave privada WireGuard, credenciais PPPoE, IPs autorizados)
  ficam **apenas no estado local do host** (`chmod 600`) e **nunca** em arquivos
  versionados no Git.
- `hosts.csv` real é ignorado pelo Git; o repositório traz apenas o `.example`.

## 7. Automação da implantação

Cada casa é instalada por um fluxo único e resumível:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/GlGontijo/UFTM-Proxmox-Casas/main/bootstrap.sh)"
```

| Etapa | Script | Resultado |
|-------|--------|-----------|
| Base | `bootstrap.sh` | Valida Proxmox 9.0–9.2.x, ajusta repositórios, atualiza o sistema e clona o repositório. |
| 1 | `bin/wizard.sh` | Único questionário do projeto; grava cada resposta assim que é dada (resumível). |
| 2 | `bin/download-deps.sh` | Todos os pacotes e a imagem OPNsense/backup, enquanto ainda há internet no laboratório. |
| 3 | `bin/network-install.sh` | Escreve a rede final (WAN/LAN trunk/console) de forma determinística. |
| 4 | `bin/hostname-and-restart.sh` | Hostname final (`<base>-<patrimônio>`), `/etc/hosts` e reinício de serviços. |
| 5 | `bin/sdn-install.sh` + `bin/evpn-bind-vlan.sh` | Fabric WireGuard, controller/zone EVPN, vnets das VLANs e binds persistentes. |
| 6 | `bin/opnsense-vm.sh` | VM OPNsense com primeiro boot automatizado e restauração opcional do `config.xml`. |
| 7 | `bin/pve-firewall-config.sh` | SNMP, Syslog, regras de firewall e ativação do `pve-firewall`. |
| 8 | `setup.sh` | Resumo final e reboot opcional para validar o boot completo. |

Os dados básicos de cada site (hostname base, porta e IP de túnel WireGuard,
se terá OPNsense, origem do backup) vêm de `data/hosts.csv`, ou são informados
manualmente pelo wizard.

## 8. Adicionando uma nova VLAN

1. Obter **autorização e justificativa no DIT - ProTIC**.
2. Selecioná-la como VLAN extra no wizard (ou incluí-la em `DEFAULT_VLANS`, se
   passar a ser padrão da UFTM).
3. Reexecutar `sdn-install.sh` (cria o `vnetXXXX`, de forma idempotente) e
   `evpn-bind-vlan.sh`.
4. Reiniciar o serviço para recarregar a lista de interfaces monitoradas:
   `systemctl restart uftm-evpn-bind-vlan.service`.
5. Garantir que a VLAN esteja no trunk do switch da casa e no lado da matriz.

## 9. Riscos e pontos de atenção

- **Domínio de broadcast ampliado:** cada VLAN estendida propaga broadcast
  entre sites. Por isso a lista é curta e controlada.
- **Dependência do hub:** a malha é hub-and-spoke; a disponibilidade do hub
  afeta todas as casas.
- **Qualidade da WAN:** latência, perda e MTU do provedor impactam VoIP e CFTV.
- **API de Fabrics do PVE 9.2 é recente:** validar em ambiente de testes antes de
  produção e comparar `/etc/pve/sdn/*.cfg` com um site já correto.
- **Chave privada WireGuard:** dependendo da versão do PVE, pode ser necessário
  informá-la manualmente em *Datacenter > SDN > Fabrics*.

## 10. Resumo

| Necessidade | Como o projeto atende |
|-------------|----------------------|
| Gerência remota dos equipamentos | VLAN 1010 estendida via EVPN/VXLAN sobre WireGuard |
| Telefonia VoIP sem custo de ramais remotos | VLAN 1011 estendida até o PBX da matriz |
| CFTV sincronizado com a central | VLAN 1012 estendida |
| Ponto eletrônico sem coleta manual | VLAN 1054 estendida até os servidores de pessoal |
| Sem licenciamento por site, com gerência | Proxmox VE + FRR + WireGuard + OPNsense |
| Padronização e repetibilidade | Instalação automatizada, idempotente e resumível |
| Governança | Novas VLANs somente com autorização do DIT - ProTIC |

---

Licença: MIT.
