#!/usr/bin/env bash
#
# install-sdn-zone.sh
# Cria (ou recria) a estrutura SDN de um site Proxmox VE 9:
#   - SDN Fabric WireGuard (node local "internal" + hub "external")
#   - Controller EVPN
#   - Zone EVPN + VNets (VLANs fixas)
#   - Zone simple (SNAT) + VNet + Subnet
#
# Uso:
#   ./install-sdn-zone.sh [-c /caminho/hosts.csv]
#
# Autor: Guilherme de Lima Gontijo - UFTM
#
# ATENÇÃO: a seção "SDN FABRIC (WireGuard)" usa uma API muito recente
# (PVE 9.2, WireGuard como protocolo de fabric). Os parâmetros abaixo
# foram montados com base na documentação disponível até o momento,
# mas ainda NÃO foram 100% confirmados linha a linha contra o
# comportamento real da API. Rode primeiro em um pve de testes,
# compare o /etc/pve/sdn/*.cfg gerado com o de um site já validado
# (ex: pve-odonto) e só então use em produção. Pontos marcados com
# "# VALIDAR" merecem atenção extra.

set -euo pipefail
shopt -s inherit_errexit

# ─────────────────────────────────────────────────────────────
# CORES / HELPERS DE MENSAGEM
# ─────────────────────────────────────────────────────────────
RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

msg_info()  { echo -ne " ${HOLD} ${YW}$1..."; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }

# ─────────────────────────────────────────────────────────────
# VARIÁVEIS FIXAS DO PROJETO (ajuste aqui se o hub/ASN mudar)
# ─────────────────────────────────────────────────────────────
FABRIC_ID="WG-FAB"
FABRIC_KEEPALIVE=10

HUB_NODE_ID="pve-vpnserver"
HUB_ENDPOINT="pgdprotic.uftm.edu.br:51820"
HUB_PUBKEY="Rln4PMSU5niFAJ8zGEawTQuibSjlXwffSERgIMe3QBY="
HUB_ALLOWED_IPS="10.255.255.1/32"
HUB_TUNNEL_IP="10.255.255.1"

EVPN_CONTROLLER="evpnctl"
EVPN_ASN=65000
EVPN_ZONE="evpnzn"
EVPN_VRF_VXLAN=100
EVPN_MTU=1360

SNAT_ZONE="snatzn"
SNAT_VNET="vnetsnat"
SNAT_SUBNET="172.31.0.0/30"
SNAT_GATEWAY="172.31.0.1"
SNAT_ALIAS="SNAT to VM Interfaces"

# Lista fixa de VLANs propagadas (mesma para todos os sites)
VLANS=(1010 1011 1012 1022 1054 1630)

CSV_FILE="./data/hosts.csv"

# ─────────────────────────────────────────────────────────────
# ARGUMENTOS
# ─────────────────────────────────────────────────────────────
while getopts "c:" opt; do
  case "$opt" in
  c) CSV_FILE="$OPTARG" ;;
  *) echo "Uso: $0 [-c caminho/hosts.csv]"; exit 1 ;;
  esac
done

if [[ ! -f "$CSV_FILE" ]]; then
  msg_error "Arquivo CSV não encontrado: $CSV_FILE"
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# FUNÇÕES DE APOIO
# ─────────────────────────────────────────────────────────────

# Gera um MAC no OUI do Proxmox (BC:24:11:xx:xx:xx)
generate_mac() {
  printf 'BC:24:11:%02X:%02X:%02X\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

# Verifica se um objeto pvesh já existe (retorna 0 se existe)
pvesh_exists() {
  local path="$1"
  pvesh get "$path" &>/dev/null
}

# Pergunta ao usuário se deve sobrescrever (retorna 0=sim, 1=não)
confirm_overwrite() {
  local label="$1"
  whiptail --backtitle "SDN Zone Installer" --title "Objeto já existe" \
    --yesno "O objeto '$label' já existe.\n\nDeseja SOBRESCREVER (apagar e recriar)?" 0 0
}

# ─────────────────────────────────────────────────────────────
# SELEÇÃO DE HOST (CSV ou manual)
# ─────────────────────────────────────────────────────────────
# Formato esperado do CSV (delimitador ";", com cabeçalho):
# Host;IP_WAN;WG_Endpoint;WG_PK;WG_TunnelIP;OPNsense

select_host_from_csv() {
  local menu_items=()
  local hosts=()
  while IFS=';' read -r host _; do
    [[ "$host" == "Host" || -z "$host" ]] && continue
    hosts+=("$host")
    menu_items+=("$host" "")
  done <"$CSV_FILE"
  menu_items+=("MANUAL" "Configuração avançada (informar manualmente)")

  local choice
  choice=$(whiptail --backtitle "SDN Zone Installer" --title "Selecione o Host" \
    --menu "Escolha o host (dados vêm da planilha) ou configure manualmente:" 0 70 12 \
    "${menu_items[@]}" 3>&2 2>&1 1>&3) || exit 1
  echo "$choice"
}

lookup_host_row() {
  local target="$1"
  awk -F';' -v h="$target" '
    NR==1 { next }
    $1==h { print; found=1 }
    END { if (!found) exit 1 }
  ' "$CSV_FILE"
}

manual_input() {
  HOSTNAME_SEL=$(whiptail --inputbox "Hostname (deve bater com o hostname real do Proxmox):" 0 70 "$(hostname)" 3>&2 2>&1 1>&3) || exit 1
  IP_WAN=$(whiptail --inputbox "IP WAN:" 0 70 3>&2 2>&1 1>&3) || exit 1
  WG_ENDPOINT=$(whiptail --inputbox "WG Endpoint (IP:Porta) deste site:" 0 70 3>&2 2>&1 1>&3) || exit 1
  WG_TUNNEL_IP=$(whiptail --inputbox "IP do túnel WireGuard (ex: 10.255.255.X):" 0 70 3>&2 2>&1 1>&3) || exit 1

  if whiptail --yesno "Gerar novo par de chaves WireGuard agora (wg genkey)?" 0 0; then
    command -v wg &>/dev/null || { msg_error "Comando 'wg' não encontrado"; exit 1; }
    WG_PK=$(wg genkey)
    msg_ok "Chave privada gerada (guarde-a em local seguro; não será exibida novamente)"
  else
    WG_PK=$(whiptail --inputbox "Chave privada WireGuard (WG_PK):" 0 70 3>&2 2>&1 1>&3) || exit 1
  fi

  OPNSENSE_SEL=$(whiptail --menu "Instalar VM OPNsense neste site?" 0 60 2 \
    "s" "Sim" "n" "Não" 3>&2 2>&1 1>&3) || exit 1
}

HOST_CHOICE=$(select_host_from_csv)

if [[ "$HOST_CHOICE" == "MANUAL" ]]; then
  manual_input
else
  ROW=$(lookup_host_row "$HOST_CHOICE") || { msg_error "Host '$HOST_CHOICE' não encontrado no CSV"; exit 1; }
  IFS=';' read -r HOSTNAME_SEL IP_WAN WG_ENDPOINT WG_PK WG_TUNNEL_IP OPNSENSE_SEL <<<"$ROW"
fi

msg_ok "Host selecionado: $HOSTNAME_SEL (tunnel ip: $WG_TUNNEL_IP)"

# ─────────────────────────────────────────────────────────────
# CONFIRMAÇÃO GERAL
# ─────────────────────────────────────────────────────────────
SUMMARY="Host: $HOSTNAME_SEL
IP WAN: $IP_WAN
WG Endpoint: $WG_ENDPOINT
WG Tunnel IP: $WG_TUNNEL_IP
OPNsense: $OPNSENSE_SEL
VLANs: ${VLANS[*]}

Confirma a criação da estrutura SDN com estes dados?"
whiptail --backtitle "SDN Zone Installer" --title "Confirmação" --yesno "$SUMMARY" 0 0 || { msg_error "Cancelado pelo usuário"; exit 1; }

# ─────────────────────────────────────────────────────────────
# 1) SDN FABRIC (WireGuard)  # VALIDAR em pve-testes-gontijo antes de produção
# ─────────────────────────────────────────────────────────────
msg_info "Verificando/criando Fabric $FABRIC_ID"
if ! pvesh_exists "/cluster/sdn/fabrics/$FABRIC_ID"; then
  pvesh create /cluster/sdn/fabrics \
    fabric="$FABRIC_ID" \
    protocol=wireguard \
    persistent_keepalive="$FABRIC_KEEPALIVE"
  msg_ok "Fabric $FABRIC_ID criado"
else
  msg_ok "Fabric $FABRIC_ID já existe (mantido)"
fi

# Node interno (este host)
NODE_INTERNAL_PATH="/cluster/sdn/fabrics/node/$FABRIC_ID"
if pvesh_exists "$NODE_INTERNAL_PATH/$HOSTNAME_SEL"; then
  if confirm_overwrite "fabric node $HOSTNAME_SEL"; then
    pvesh delete "$NODE_INTERNAL_PATH/$HOSTNAME_SEL"
    CREATE_INTERNAL=1
  else
    CREATE_INTERNAL=0
  fi
else
  CREATE_INTERNAL=1
fi

if [[ "$CREATE_INTERNAL" -eq 1 ]]; then
  msg_info "Criando fabric node interno ($HOSTNAME_SEL)"
  # VALIDAR: parâmetro de chave privada pode não existir nesta API;
  # em alguns builds a private key é gerada automaticamente pelo PVE
  # e armazenada em /etc/pve/priv/wg-keys.cfg. Se o comando abaixo
  # falhar reclamando de "private_key" desconhecido, rode sem ele
  # (deixe o Proxmox gerar) e depois cheque a chave pública gerada
  # com: pvesh get /cluster/sdn/fabrics/node/$FABRIC_ID/$HOSTNAME_SEL
  pvesh create "$NODE_INTERNAL_PATH" \
    node="$HOSTNAME_SEL" \
    protocol=wireguard \
    role=internal \
    interfaces="name=wg0,listen_port=51820,ip=${WG_TUNNEL_IP}/24" \
    allowed_ips="${WG_TUNNEL_IP%.*}.0/24" \
    private_key="$WG_PK"
  msg_ok "Fabric node interno criado"
fi

# Node externo (hub) — fixo, mesmo em todo site
if pvesh_exists "$NODE_INTERNAL_PATH/$HUB_NODE_ID"; then
  msg_ok "Fabric node externo (hub $HUB_NODE_ID) já existe (mantido)"
else
  msg_info "Criando fabric node externo (hub $HUB_NODE_ID)"
  pvesh create "$NODE_INTERNAL_PATH" \
    node="$HUB_NODE_ID" \
    protocol=wireguard \
    role=external \
    endpoint="$HUB_ENDPOINT" \
    public_key="$HUB_PUBKEY" \
    allowed_ips="$HUB_ALLOWED_IPS"
  msg_ok "Fabric node externo (hub) criado"
fi

# ─────────────────────────────────────────────────────────────
# 2) EVPN CONTROLLER
# ─────────────────────────────────────────────────────────────
if pvesh_exists "/cluster/sdn/controllers/$EVPN_CONTROLLER"; then
  if confirm_overwrite "controller $EVPN_CONTROLLER"; then
    pvesh delete "/cluster/sdn/controllers/$EVPN_CONTROLLER"
    CREATE_CTRL=1
  else
    CREATE_CTRL=0
  fi
else
  CREATE_CTRL=1
fi

if [[ "$CREATE_CTRL" -eq 1 ]]; then
  msg_info "Criando controller EVPN ($EVPN_CONTROLLER)"
  pvesh create /cluster/sdn/controllers \
    type=evpn \
    controller="$EVPN_CONTROLLER" \
    asn="$EVPN_ASN" \
    peers="${HUB_TUNNEL_IP},${WG_TUNNEL_IP}"
  msg_ok "Controller EVPN criado"
fi

# ─────────────────────────────────────────────────────────────
# 3) EVPN ZONE
# ─────────────────────────────────────────────────────────────
if pvesh_exists "/cluster/sdn/zones/$EVPN_ZONE"; then
  if confirm_overwrite "zone $EVPN_ZONE"; then
    pvesh delete "/cluster/sdn/zones/$EVPN_ZONE"
    CREATE_ZONE=1
  else
    CREATE_ZONE=0
  fi
else
  CREATE_ZONE=1
fi

if [[ "$CREATE_ZONE" -eq 1 ]]; then
  ZONE_MAC=$(generate_mac)
  msg_info "Criando zone EVPN ($EVPN_ZONE, mac $ZONE_MAC)"
  pvesh create /cluster/sdn/zones \
    type=evpn \
    zone="$EVPN_ZONE" \
    controller="$EVPN_CONTROLLER" \
    vrf-vxlan="$EVPN_VRF_VXLAN" \
    ipam=pve \
    mac="$ZONE_MAC" \
    mtu="$EVPN_MTU"
  msg_ok "Zone EVPN criada"
fi

# ─────────────────────────────────────────────────────────────
# 4) VNETS (uma por VLAN, lista fixa)
# ─────────────────────────────────────────────────────────────
for vlan in "${VLANS[@]}"; do
  vnet="vnet${vlan}"
  if pvesh_exists "/cluster/sdn/vnets/$vnet"; then
    if confirm_overwrite "vnet $vnet"; then
      pvesh delete "/cluster/sdn/vnets/$vnet"
    else
      msg_ok "Vnet $vnet mantido (não sobrescrito)"
      continue
    fi
  fi
  msg_info "Criando vnet $vnet (VLAN $vlan)"
  pvesh create /cluster/sdn/vnets \
    vnet="$vnet" \
    zone="$EVPN_ZONE" \
    tag="$vlan" \
    alias="Vnet Bridge Vlan${vlan}"
  msg_ok "Vnet $vnet criado"
done

# ─────────────────────────────────────────────────────────────
# 5) ZONE SIMPLE (SNAT) + VNET + SUBNET
# ─────────────────────────────────────────────────────────────
if pvesh_exists "/cluster/sdn/zones/$SNAT_ZONE"; then
  if confirm_overwrite "zone $SNAT_ZONE"; then
    pvesh delete "/cluster/sdn/zones/$SNAT_ZONE"
    CREATE_SNAT_ZONE=1
  else
    CREATE_SNAT_ZONE=0
  fi
else
  CREATE_SNAT_ZONE=1
fi

if [[ "$CREATE_SNAT_ZONE" -eq 1 ]]; then
  msg_info "Criando zone simple ($SNAT_ZONE)"
  pvesh create /cluster/sdn/zones \
    type=simple \
    zone="$SNAT_ZONE" \
    ipam=pve
  msg_ok "Zone SNAT criada"
fi

if pvesh_exists "/cluster/sdn/vnets/$SNAT_VNET"; then
  if confirm_overwrite "vnet $SNAT_VNET"; then
    pvesh delete "/cluster/sdn/vnets/$SNAT_VNET"
    CREATE_SNAT_VNET=1
  else
    CREATE_SNAT_VNET=0
  fi
else
  CREATE_SNAT_VNET=1
fi

if [[ "$CREATE_SNAT_VNET" -eq 1 ]]; then
  msg_info "Criando vnet $SNAT_VNET"
  pvesh create /cluster/sdn/vnets \
    vnet="$SNAT_VNET" \
    zone="$SNAT_ZONE" \
    alias="$SNAT_ALIAS"
  msg_ok "Vnet SNAT criado"

  msg_info "Criando subnet $SNAT_SUBNET"
  pvesh create "/cluster/sdn/vnets/$SNAT_VNET/subnets" \
    subnet="$SNAT_SUBNET" \
    gateway="$SNAT_GATEWAY" \
    snat=1
  msg_ok "Subnet SNAT criada"
fi

# ─────────────────────────────────────────────────────────────
# 6) APLICAR CONFIGURAÇÃO SDN
# ─────────────────────────────────────────────────────────────
msg_info "Aplicando configuração SDN (pvesh set /cluster/sdn)"
pvesh set /cluster/sdn
msg_ok "Configuração SDN aplicada"

# ─────────────────────────────────────────────────────────────
# 7) OPNSENSE (opcional)
# ─────────────────────────────────────────────────────────────
if [[ "$OPNSENSE_SEL" =~ ^[SsYy] ]]; then
  if [[ -x "./bin/install_vm_opnsense.sh" ]]; then
    msg_info "Executando install_vm_opnsense.sh"
    ./bin/install_vm_opnsense.sh
    msg_ok "OPNsense instalado"
  else
    msg_error "bin/install_vm_opnsense.sh não encontrado ou sem permissão de execução"
  fi
else
  msg_ok "OPNsense não solicitado para este host"
fi

msg_ok "Estrutura SDN concluída para $HOSTNAME_SEL"
