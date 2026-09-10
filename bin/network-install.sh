#!/usr/bin/env bash
#
# bin/network-install.sh
# Configura WAN (DHCP / IP Fixo / PPPoE) e a bridge de trunk da LAN.
#
# IMPORTANTE (lição aprendida do projeto): isto NUNCA escreve em
# /etc/network/interfaces.d/sdn -- esse arquivo é gerenciado pelo ciclo de
# vida do Proxmox SDN e qualquer edição manual lá é sobrescrita/entra em
# conflito. Este script edita apenas o arquivo principal
# /etc/network/interfaces, dentro de um bloco demarcado
# (# >>> UFTM-NETWORK-INSTALL / # <<< UFTM-NETWORK-INSTALL), que é o ponto de
# merge suportado pelo ifupdown2. As vnets/fabric ficam por conta do
# sdn-install.sh via pvesh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

IFACES_FILE="/etc/network/interfaces"
MARK_BEGIN="# >>> UFTM-NETWORK-INSTALL (gerado automaticamente, não editar à mão) >>>"
MARK_END="# <<< UFTM-NETWORK-INSTALL <<<"
PEER_NAME="pppoe0"
PEER_FILE="/etc/ppp/peers/$PEER_NAME"

# ── Detecta NICs físicas (exclui virtuais/bridges/túneis) ──────
mapfile -t NIC_LIST < <(ip -o link show | awk -F': ' '{print $2}' | \
  grep -Ev '^(lo|vmbr|wg|vnet|fwbr|fwln|tap|veth|pppoe|bond)')

if [[ "${#NIC_LIST[@]}" -eq 0 ]]; then
  msg_error "Nenhuma interface física detectada."
  exit 1
fi

nic_menu() {
  local m=()
  for n in "${NIC_LIST[@]}"; do
    local mac state
    mac=$(cat "/sys/class/net/$n/address" 2>/dev/null || echo "?")
    state=$(cat "/sys/class/net/$n/operstate" 2>/dev/null || echo "?")
    m+=("$n" "$mac / $state")
  done
  whiptail --menu "$1" 0 70 "${#NIC_LIST[@]}" "${m[@]}" 3>&2 2>&1 1>&3
}

# find_bridge_for_nic <nic> -> imprime nome da bridge se a NIC já estiver escravizada
find_bridge_for_nic() {
  local nic="$1" br
  for br in /sys/class/net/*/brif/"$nic"; do
    [[ -e "$br" ]] || continue
    basename "$(dirname "$(dirname "$br")")"
    return 0
  done
  return 1
}

confirm_or_new_bridge() {
  # $1 = nic ; $2 = uso (WAN/LAN/Console) ; $3-nameref pra devolver o nome da bridge
  local nic="$1" uso="$2" __outvar="$3" existing br_name
  if existing=$(find_bridge_for_nic "$nic" 2>/dev/null); then
    if whiptail --yesno "A interface '$nic' já está escravizada na bridge '$existing'.\nReutilizar essa bridge para $uso?" 0 0; then
      printf -v "$__outvar" '%s' "$existing"
      return 0
    fi
  fi
  br_name=$(whiptail --inputbox "Nome da bridge para $uso (ex: vmbr0):" 0 60 "vmbr$((RANDOM % 8))" 3>&2 2>&1 1>&3) || exit 1
  printf -v "$__outvar" '%s' "$br_name"
}

# ── WAN: interface física ───────────────────────────────────────
WAN_NIC=$(nic_menu "Interface física para WAN:") || exit 1
confirm_or_new_bridge "$WAN_NIC" "WAN" WAN_BRIDGE

WAN_MODE=$(whiptail --menu "Modo de conexão da WAN:" 0 60 3 \
  "dhcp"   "DHCP" \
  "static" "IP Fixo" \
  "pppoe"  "PPPoE (provedor UFTM)" \
  3>&2 2>&1 1>&3) || exit 1

WAN_IP=""; WAN_MASK=""; WAN_GW=""; PPPOE_USER=""; PPPOE_PASS=""; PPPOE_MTU=1492

case "$WAN_MODE" in
  static)
    WAN_IP=$(whiptail --inputbox "IP/CIDR da WAN (ex: 200.1.2.3/29):" 0 60 3>&2 2>&1 1>&3) || exit 1
    WAN_GW=$(whiptail --inputbox "Gateway da WAN:" 0 60 3>&2 2>&1 1>&3) || exit 1
    ;;
  pppoe)
    PPPOE_USER=$(whiptail --inputbox "Usuário PPPoE:" 0 60 3>&2 2>&1 1>&3) || exit 1
    PPPOE_PASS=$(whiptail --passwordbox "Senha PPPoE:" 0 60 3>&2 2>&1 1>&3) || exit 1
    PPPOE_MTU=$(whiptail --inputbox "MTU do PPPoE (padrão 1492):" 0 60 "1492" 3>&2 2>&1 1>&3) || exit 1
    [[ -z "$PPPOE_USER" || -z "$PPPOE_PASS" ]] && { msg_error "Usuário e senha PPPoE são obrigatórios."; exit 1; }

    msg_info "Testando descoberta PPPoE em $WAN_BRIDGE (pode falhar se a bridge ainda não existir -- ok por ora)"
    if ip link show "$WAN_BRIDGE" &>/dev/null; then
      OUT=$(timeout 8 pppoe-discovery -I "$WAN_BRIDGE" 2>&1) || true
      if echo "$OUT" | grep -qi "AC-Name\|Access-Concentrator\|Service-Name"; then
        msg_ok "Discovery OK em $WAN_BRIDGE"
      else
        msg_warn "Sem resposta de discovery em $WAN_BRIDGE ainda (normal se a bridge for criada só agora)."
      fi
    fi
    ;;
esac

# ── LAN: interface física de trunk ──────────────────────────────
LAN_NIC=$(nic_menu "Interface física de trunk para a LAN (VLANs 1010/1011/1012/1022/1054/1630 etc.):") || exit 1
if [[ "$LAN_NIC" == "$WAN_NIC" ]]; then
  msg_error "A interface de LAN não pode ser a mesma da WAN."
  exit 1
fi
confirm_or_new_bridge "$LAN_NIC" "LAN (trunk)" LAN_BRIDGE

# ── Console de gerência (opcional) ──────────────────────────────
CONSOLE_BRIDGE=""
if whiptail --yesno "Configurar uma interface dedicada de console/gerência (ex: vmcsl, 192.168.100.1/24)?" 0 0; then
  CONSOLE_NIC=$(nic_menu "Interface física para console:") || exit 1
  confirm_or_new_bridge "$CONSOLE_NIC" "Console" CONSOLE_BRIDGE
  CONSOLE_CIDR=$(whiptail --inputbox "IP/CIDR do console:" 0 60 "192.168.100.1/24" 3>&2 2>&1 1>&3) || exit 1
fi

# ── Monta o bloco de configuração ───────────────────────────────
backup_if_exists "$IFACES_FILE"

# Remove bloco anterior (reexecução idempotente)
if grep -qF "$MARK_BEGIN" "$IFACES_FILE" 2>/dev/null; then
  sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$IFACES_FILE"
fi

{
  echo "$MARK_BEGIN"
  echo "# Gerado em $(date -Iseconds) por network-install.sh -- não editar à mão."
  echo "# Reexecute o script para alterar; ele substitui só este bloco."
  echo

  case "$WAN_MODE" in
    dhcp)
      cat <<EOF
auto $WAN_NIC
iface $WAN_NIC inet manual

auto $WAN_BRIDGE
iface $WAN_BRIDGE inet dhcp
    bridge-ports $WAN_NIC
    bridge-stp off
    bridge-fd 0
EOF
      ;;
    static)
      IFS='/' read -r WAN_ADDR WAN_CIDR <<<"$WAN_IP"
      cat <<EOF
auto $WAN_NIC
iface $WAN_NIC inet manual

auto $WAN_BRIDGE
iface $WAN_BRIDGE inet static
    address $WAN_IP
    gateway $WAN_GW
    bridge-ports $WAN_NIC
    bridge-stp off
    bridge-fd 0
EOF
      ;;
    pppoe)
      cat <<EOF
auto $WAN_NIC
iface $WAN_NIC inet manual

auto $WAN_BRIDGE
iface $WAN_BRIDGE inet manual
    bridge-ports $WAN_NIC
    bridge-stp off
    bridge-fd 0

auto pppoe0
iface pppoe0 inet ppp
    pre-up /usr/local/bin/uftm-wait-for-iface.sh "$WAN_BRIDGE" || true
    provider $PEER_NAME
EOF
      ;;
  esac

  echo
  cat <<EOF
auto $LAN_NIC
iface $LAN_NIC inet manual

auto $LAN_BRIDGE
iface $LAN_BRIDGE inet manual
    bridge-ports $LAN_NIC
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
EOF

  if [[ -n "$CONSOLE_BRIDGE" ]]; then
    echo
    cat <<EOF
auto $CONSOLE_NIC
iface $CONSOLE_NIC inet manual

auto $CONSOLE_BRIDGE
iface $CONSOLE_BRIDGE inet static
    address $CONSOLE_CIDR
    bridge-ports $CONSOLE_NIC
    bridge-stp off
    bridge-fd 0
EOF
  fi

  echo "$MARK_END"
} >>"$IFACES_FILE"

msg_ok "Bloco de rede gravado em $IFACES_FILE"

# ── PPPoE: peers file, secrets, wait-script ─────────────────────
if [[ "$WAN_MODE" == "pppoe" ]]; then
  backup_if_exists "$PEER_FILE"
  cat >"$PEER_FILE" <<EOF
plugin rp-pppoe.so
$WAN_BRIDGE
ifname pppoe0

persist
maxfail 0
holdoff 5

lcp-echo-interval 5
lcp-echo-failure 3

mtu $PPPOE_MTU
mru $PPPOE_MTU

noauth
noipdefault
defaultroute
replacedefaultroute
usepeerdns

user "$PPPOE_USER"
EOF
  msg_ok "Peer PPPoE gravado em $PEER_FILE (apontando para a bridge $WAN_BRIDGE, não para a NIC física)"

  for SECRETS_FILE in /etc/ppp/chap-secrets /etc/ppp/pap-secrets; do
    backup_if_exists "$SECRETS_FILE"
    touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
    LINE="\"$PPPOE_USER\" * \"$PPPOE_PASS\" *"
    grep -qF "\"$PPPOE_USER\"" "$SECRETS_FILE" 2>/dev/null && sed -i "\|\"$PPPOE_USER\"|d" "$SECRETS_FILE"
    echo "$LINE" >>"$SECRETS_FILE"
  done
  msg_ok "Credenciais gravadas em chap-secrets e pap-secrets (provedores BR variam entre PAP/CHAP, pppd escolhe sozinho)"

  install -m 0755 /dev/stdin /usr/local/bin/uftm-wait-for-iface.sh <<'EOF'
#!/bin/bash
# Aguarda a bridge de uplink ficar UP (e fora de STP listening/learning,
# se aplicável) antes do PPPoE subir por cima dela.
IFACE="$1"
TIMEOUT=30
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  if ip link show "$IFACE" 2>/dev/null | grep -q "state UP"; then
    if bridge -d link show 2>/dev/null | grep -q "$IFACE.*state forwarding\|$IFACE.*state disabled"; then
      exit 0
    elif ! bridge -d link show 2>/dev/null | grep -q "$IFACE"; then
      exit 0
    fi
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
logger -t uftm-network "Timeout aguardando $IFACE ficar pronta para PPPoE"
exit 1
EOF
  msg_ok "Helper de espera instalado em /usr/local/bin/uftm-wait-for-iface.sh"

  export UFTM_WAN_MODE="pppoe"
else
  export UFTM_WAN_MODE="$WAN_MODE"
fi

export UFTM_WAN_BRIDGE="$WAN_BRIDGE" UFTM_LAN_BRIDGE="$LAN_BRIDGE"
mkdir -p "$UFTM_ETC_DIR"
cat >"$UFTM_ETC_DIR/network.env" <<EOF
UFTM_WAN_MODE=$UFTM_WAN_MODE
UFTM_WAN_BRIDGE=$WAN_BRIDGE
UFTM_LAN_BRIDGE=$LAN_BRIDGE
UFTM_CONSOLE_BRIDGE=${CONSOLE_BRIDGE:-}
EOF
msg_ok "Estado salvo em $UFTM_ETC_DIR/network.env (usado pelo sdn-install.sh e evpn-bind-vlan.sh)"

msg_warn "As mudanças em $IFACES_FILE ainda não foram aplicadas (evitando lockout). Rode 'ifreload -a' manualmente ou reinicie ao final do setup."
