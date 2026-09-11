#!/usr/bin/env bash
#
# bin/network-install.sh
# ETAPA 4 do fluxo. Aplica a configuração de rede coletada no wizard (etapa
# 2) -- este script NÃO pergunta nada, só lê o estado e escreve os arquivos.
#
# A PARTIR DAQUI a conexão com a internet do laboratório pode ser perdida de
# propósito (a rede está sendo reconfigurada para o site final).
#
# Regras seguidas aqui (lições do projeto):
#   - NUNCA editar /etc/network/interfaces.d/sdn (gerenciado pelo SDN).
#   - /etc/network/interfaces é reescrito de forma DETERMINÍSTICA e completa
#     a cada execução (loopback + bloco gerenciado), nunca por patch
#     incremental -- isso elimina duplicação mesmo que uma execução anterior
#     tenha ficado num estado inconsistente.
#   - A ÚLTIMA linha do arquivo é sempre "source /etc/network/interfaces.d/*"
#     (garante que os fragmentos -- incluindo o do SDN -- só sobem depois
#     das interfaces principais já declaradas aqui).
#   - pppoe0 vai INTEIRO para seu próprio /etc/network/interfaces.d/pppoe0,
#     nunca dentro do arquivo principal.
#   - Nenhuma linha pre-up/up/pre-down é escrita DENTRO de um iface stanza.
#     Toda lógica condicional mora em scripts globais de
#     /etc/network/if-pre-up.d/ e /etc/network/if-up.d/, cada um checando
#     "$IFACE" antes de agir -- é o padrão que o ifupdown2 já usa nativamente
#     e evita reescrever o interfaces/interfaces.d a cada ajuste de hook.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
state_load

: "${UFTM_NET_DONE:?Rode bin/wizard.sh primeiro (etapa 2) -- dados de rede ausentes}"

IFACES_FILE="/etc/network/interfaces"
IFACES_D="/etc/network/interfaces.d"
PPPOE_IFACE_FILE="$IFACES_D/pppoe0"
PEER_NAME="pppoe0"
PEER_FILE="/etc/ppp/peers/$PEER_NAME"
SOURCE_LINE="source $IFACES_D/*"

mkdir -p "$IFACES_D"
backup_if_exists "$IFACES_FILE"

# ── 1) Preserva o stanza de loopback (ou cria um padrão) ─────────
LOOPBACK_BLOCK="auto lo
iface lo inet loopback"
if [[ -f "$IFACES_FILE" ]] && grep -q "^iface lo inet loopback" "$IFACES_FILE"; then
  LOOPBACK_BLOCK=$(awk '/^auto lo/{f=1} f{print; if(/^iface lo inet loopback/){exit}}' "$IFACES_FILE")
fi

# ── 2) Monta o bloco de bridges (WAN/LAN/console) ────────────────
build_bridge_block() {
  case "$UFTM_WAN_MODE" in
    dhcp)
      cat <<EOF
auto $UFTM_WAN_NIC
iface $UFTM_WAN_NIC inet manual

auto $UFTM_WAN_BRIDGE
iface $UFTM_WAN_BRIDGE inet dhcp
    bridge-ports $UFTM_WAN_NIC
    bridge-stp off
    bridge-fd 0
EOF
      ;;
    static)
      cat <<EOF
auto $UFTM_WAN_NIC
iface $UFTM_WAN_NIC inet manual

auto $UFTM_WAN_BRIDGE
iface $UFTM_WAN_BRIDGE inet static
    address $UFTM_WAN_IP
    gateway $UFTM_WAN_GW
    bridge-ports $UFTM_WAN_NIC
    bridge-stp off
    bridge-fd 0
EOF
      ;;
    pppoe)
      # pppoe0 em si NÃO entra aqui -- vai para interfaces.d/pppoe0 exclusivo
      cat <<EOF
auto $UFTM_WAN_NIC
iface $UFTM_WAN_NIC inet manual

auto $UFTM_WAN_BRIDGE
iface $UFTM_WAN_BRIDGE inet manual
    bridge-ports $UFTM_WAN_NIC
    bridge-stp off
    bridge-fd 0
EOF
      ;;
  esac

  echo
  cat <<EOF
auto $UFTM_LAN_NIC
iface $UFTM_LAN_NIC inet manual

auto $UFTM_LAN_BRIDGE
iface $UFTM_LAN_BRIDGE inet manual
    bridge-ports $UFTM_LAN_NIC
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
EOF

  if [[ -n "${UFTM_CONSOLE_BRIDGE:-}" ]]; then
    echo
    cat <<EOF
auto $UFTM_CONSOLE_NIC
iface $UFTM_CONSOLE_NIC inet manual

auto $UFTM_CONSOLE_BRIDGE
iface $UFTM_CONSOLE_BRIDGE inet static
    address $UFTM_CONSOLE_CIDR
    bridge-ports $UFTM_CONSOLE_NIC
    bridge-stp off
    bridge-fd 0
EOF
  fi
}

# ── 3) Reescreve /etc/network/interfaces do zero (determinístico) ──
{
  echo "$LOOPBACK_BLOCK"
  echo
  echo "# Gerado em $(date -Iseconds) por network-install.sh -- reescrito por"
  echo "# inteiro a cada execução, não editar à mão (edições somem na próxima"
  echo "# execução do wizard). Hooks condicionais ficam em"
  echo "# /etc/network/if-up.d/ e /etc/network/if-pre-up.d/, não aqui."
  echo
  build_bridge_block
  echo
  echo "# Sempre por último: garante que os fragmentos (inclusive o do SDN,"
  echo "# gerado por /etc/pve/sdn) só sobem depois das interfaces acima."
  echo "$SOURCE_LINE"
} >"$IFACES_FILE"

msg_ok "/etc/network/interfaces reescrito (sem duplicação, source dos fragmentos por último)"

# ── 4) pppoe0 em arquivo exclusivo ────────────────────────────────
rm -f "$PPPOE_IFACE_FILE"
if [[ "$UFTM_WAN_MODE" == "pppoe" ]]; then
  cat >"$PPPOE_IFACE_FILE" <<EOF
# Gerado por network-install.sh -- pppoe0 SEMPRE fica isolado aqui, nunca
# dentro do /etc/network/interfaces principal.
auto pppoe0
iface pppoe0 inet ppp
    provider $PEER_NAME
EOF
  msg_ok "pppoe0 gravado em $PPPOE_IFACE_FILE (arquivo exclusivo)"

  backup_if_exists "$PEER_FILE"
  cat >"$PEER_FILE" <<EOF
plugin rp-pppoe.so
$UFTM_WAN_BRIDGE
ifname pppoe0

persist
maxfail 0
holdoff 5

lcp-echo-interval 5
lcp-echo-failure 3

mtu ${UFTM_PPPOE_MTU:-1492}
mru ${UFTM_PPPOE_MTU:-1492}

noauth
noipdefault
defaultroute
replacedefaultroute
usepeerdns

user "$UFTM_PPPOE_USER"
EOF
  msg_ok "Peer PPPoE gravado em $PEER_FILE (aponta para a bridge $UFTM_WAN_BRIDGE, não para a NIC física)"

  for SECRETS_FILE in /etc/ppp/chap-secrets /etc/ppp/pap-secrets; do
    backup_if_exists "$SECRETS_FILE"
    touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
    LINE="\"$UFTM_PPPOE_USER\" * \"$UFTM_PPPOE_PASS\" *"
    grep -qF "\"$UFTM_PPPOE_USER\"" "$SECRETS_FILE" 2>/dev/null && sed -i "\|\"$UFTM_PPPOE_USER\"|d" "$SECRETS_FILE"
    echo "$LINE" >>"$SECRETS_FILE"
  done
  msg_ok "Credenciais gravadas em chap-secrets/pap-secrets"
fi

# ── 5) Hooks globais (if-up/if-pre-up), NUNCA linhas dentro do interfaces ──
# Só existem quando PPPoE está em uso; removidos (idempotente) quando não.
WAIT_HOOK="/etc/network/if-pre-up.d/uftm-wait-pppoe0"
RESTART_WG_HOOK="/etc/network/if-up.d/uftm-restart-sdn-wireguard"

rm -f "$WAIT_HOOK" "$RESTART_WG_HOOK"
if [[ "$UFTM_WAN_MODE" == "pppoe" ]]; then
  cat >"$WAIT_HOOK" <<EOF
#!/bin/bash
# Gerado por network-install.sh. Roda para TODA interface que sobe (padrão
# ifupdown2); só age quando \$IFACE é pppoe0, e só deixa o pppoe0 seguir
# depois que a bridge de uplink ($UFTM_WAN_BRIDGE) estiver pronta.
TARGET_IFACE="pppoe0"
DEPEND_IFACE="$UFTM_WAN_BRIDGE"
TIMEOUT=30
INTERVAL=2

[ "\$IFACE" = "\$TARGET_IFACE" ] || exit 0

logger -t uftm-network "Aguardando \$DEPEND_IFACE subir antes de liberar \$TARGET_IFACE..."
ELAPSED=0
while ! ip link show dev "\$DEPEND_IFACE" up >/dev/null 2>&1; do
  if [ "\$ELAPSED" -ge "\$TIMEOUT" ]; then
    logger -t uftm-network "Timeout aguardando \$DEPEND_IFACE. Prosseguindo mesmo assim."
    exit 0
  fi
  sleep "\$INTERVAL"
  ELAPSED=\$((ELAPSED + INTERVAL))
done
logger -t uftm-network "\$DEPEND_IFACE pronta. Liberando \$TARGET_IFACE."
EOF
  chmod 0755 "$WAIT_HOOK"
  msg_ok "Hook if-pre-up instalado: $WAIT_HOOK (espera $UFTM_WAN_BRIDGE antes do pppoe0)"

  cat >"$RESTART_WG_HOOK" <<'EOF'
#!/bin/bash
# Gerado por network-install.sh. Reinicia wg0 (via engine SDN) sempre que
# pppoe0 sobe -- o endpoint DNS do peer pode ter mudado.
TARGET_INTERFACE="pppoe0"
WG_INTERFACE="wg0"
[ "$IFACE" = "$TARGET_INTERFACE" ] || exit 0

sleep 3
logger -t uftm-network "pppoe0 estabelecida; reiniciando $WG_INTERFACE via engine SDN"
ifdown $WG_INTERFACE --allow sdn >/dev/null 2>&1
ifup $WG_INTERFACE --allow sdn >/dev/null 2>&1
EOF
  chmod 0755 "$RESTART_WG_HOOK"
  msg_ok "Hook if-up instalado: $RESTART_WG_HOOK (reinicia wg0 quando pppoe0 sobe)"
fi

state_mark_step "network-install"
msg_ok "network-install.sh concluído -- a aplicação de fato acontece no restart de rede da etapa 5 (hostname-and-restart.sh)."
