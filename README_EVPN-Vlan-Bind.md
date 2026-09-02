# evpn-vlan-bind

Amarra subinterfaces VLAN de um trunk físico (ex.: `vmbr3.1010`) às bridges
`vnet<VLAN>` criadas pela SDN EVPN do Proxmox, estendendo de fato a VLAN até o
switch físico local, de forma persistente no boot **e** resiliente a
recriações em runtime (SDN "Apply", restart do FRR, etc).

## Por que isso existe

A GUI da SDN EVPN no Proxmox VE 9.2 não expõe um jeito nativo de linkar uma
VNET a um trunk físico. Além disso:

- O device `vnet<VLAN>` só é materializado depois que `frr.service`/zebra
  sobe — então um `post-up` dentro do próprio `/etc/network/interfaces` falha
  no boot (`networking.service` roda antes do FRR terminar).
- `ifreload -a` (disparado pelo botão "Apply" da SDN) só reexecuta hooks de
  interfaces cuja config declarada mudou — então se a VNET for recriada mas a
  subinterface VLAN não mudar, o bind antigo não é refeito automaticamente.

Este pacote resolve os dois pontos:

1. **Boot**: um serviço systemd (`evpn-vlan-bind.service`) roda *depois* do
   FRR, com retry, garantindo o bind mesmo que o EVPN demore alguns segundos
   a mais para subir.
2. **Runtime**: uma regra `udev` dispara o mesmo script sempre que um device
   `vnet*` é (re)criado — cobre SDN Apply, restart do FRR, etc.

O script de bind é idempotente: pode rodar quantas vezes for preciso, só
corrige o que estiver fora do lugar.

## Arquivos

| Arquivo | Função |
|---|---|
| `install-evpn-vlan-bind.sh` | Instalador único e parametrizado — rode este |
| `uninstall-evpn-vlan-bind.sh` | Reverte a instalação (mantém o `interfaces` intacto, exceto marcação) |

O instalador **gera** os seguintes artefatos no host:

| Gerado | Função |
|---|---|
| `/etc/network/interfaces` (bloco marcado) | Subinterfaces VLAN (`mtu` + `requires vnetXXXX`) |
| `/usr/local/sbin/evpn-vlan-bind.sh` | Script de bind, idempotente, com retry |
| `/etc/systemd/system/evpn-vlan-bind.service` | Roda o bind após `networking.service` + `frr.service` |
| `/etc/udev/rules.d/70-evpn-vnet-bind.rules` | Dispara o bind sempre que um `vnet*` for (re)criado |

## Como funciona a auto-detecção

O instalador **não pede mais** uma lista manual de VLANs. Ele descobre
sozinho, lendo a config real do host:

1. **Quais VNETs são EVPN** — lê `/etc/pve/sdn/zones.cfg` para achar zonas do
   tipo `evpn:` (ignora zonas "Simple", como a usada para a WAN do OPNsense),
   depois lê `/etc/pve/sdn/vnets.cfg` e pega a `tag` de cada VNET que
   pertence a essas zonas.
2. **Qual trunk físico carrega cada tag** — lê `/etc/network/interfaces`
   procurando bridges `bridge-vlan-aware yes` e olha o `bridge-vids` de cada
   uma (com suporte a ranges tipo `1010-1012`).
3. **Cruza os dois** — se uma tag aparece em exatamente um trunk, o bind é
   resolvido sozinho. Se aparecer em **zero** trunks, a VNET é pulada com
   aviso (ela existe na SDN mas não tem porta física neste host). Se aparecer
   em **mais de um** trunk, o instalador para essa tag específica e pede para
   você resolver manualmente (ver abaixo) — ele nunca escolhe por adivinhação
   nesse caso.

## Como aplicar em um site

1. Copie `install-evpn-vlan-bind.sh` para o Proxmox do site.
2. (Opcional) rode primeiro em modo `--dry-run` para conferir o que ele *vai*
   detectar, sem aplicar nada:
   ```bash
   bash install-evpn-vlan-bind.sh --dry-run
   ```
   Revise a saída — confira se todas as VLANs esperadas apareceram e se os
   trunks escolhidos fazem sentido para aquele site.
3. Se alguma tag aparecer como `AMBIGUO` (carregada por mais de um trunk
   vlan-aware) ou você quiser excluir alguma VLAN da automação, edite as
   variáveis no topo do arquivo:
   ```bash
   FORCE_TRUNK="1022:vmbr3"     # resolve ambiguidade: tag 1022 -> use vmbr3
   EXCLUDE_VLANS="1019 1620"    # nunca amarrar essas tags (ex: DMZ/WAN)
   MTU=1360                      # so mude se o MTU da zone EVPN for diferente
   ```
   Rode `--dry-run` de novo até a saída ficar como esperado.
4. Aplique de fato:
   ```bash
   bash install-evpn-vlan-bind.sh
   ```
5. Siga os "PRÓXIMOS PASSOS MANUAIS" impressos no final (propositalmente não
   automatizados, para você revisar antes de aplicar em produção):
   - Revisar o diff do `/etc/network/interfaces`
   - Subir as novas subinterfaces com `ifdown`/`ifup` (não `ifreload`, pelo
     motivo explicado acima)
   - Rodar o bind manualmente uma vez e conferir `master` + `mtu`
   - **Só depois de validar a quente, agendar um reboot** para confirmar o
     caminho de boot do zero

## Checklist de validação por site

```bash
# bind ok?
systemctl status evpn-vlan-bind.service

# cada VLAN com master e mtu corretos?
for v in $VLANS; do ip link show vmbr3.$v | grep -oP 'mtu \d+|master \S+'; done

# trafego real chegando na bridge (ARP, etc)?
tcpdump -ni vnet1010 -c 5

# regra udev reage a recriacao do vnet? (teste seguro, nao destrutivo)
ip link set vmbr3.1010 nomaster
udevadm trigger --action=add /sys/class/net/vnet1010
ip link show vmbr3.1010 | grep master   # deve voltar sozinho
```

## Reaplicar / quando uma nova VNET EVPN for criada depois

Como a lista de VLANs agora vem da própria config da SDN, basta rodar o
instalador de novo depois de criar uma nova VNET EVPN — ele detecta e
adiciona sozinho. Ele substitui o bloco marcado no `interfaces` e regenera
os artefatos a cada execução. VNETs **removidas** da SDN não são desfeitas
automaticamente (a subinterface antiga continua existindo); remova
manualmente do bloco marcado se necessário.

## Rollback

```bash
bash uninstall-evpn-vlan-bind.sh
```
Remove o service, a regra udev e o script. O bloco no `/etc/network/interfaces`
fica marcado entre `# BEGIN evpn-vlan-bind` / `# END evpn-vlan-bind` para
remoção manual fácil, caso deseje desfazer tudo.
