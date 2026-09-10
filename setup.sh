#!/usr/bin/env bash
#
# setup.sh
# Orquestrador principal do UFTM-Proxmox-Casas.
#
# Fluxo:
#   1) post-install.sh      - otimização base do Proxmox
#   2) network-install.sh   - WAN (DHCP/Fixo/PPPoE) + LAN trunk
#   3) sdn-install.sh       - fabric WireGuard + EVPN/VXLAN + vnets + SNAT
#   4) evpn-bind-vlan.sh    - serviço de bind persistente das interfaces de trunk
#   5) opnsense-vm.sh       - VM OPNsense (se solicitado no CSV/manual)
#   6) reboot opcional
#
# Chamado normalmente pelo bootstrap.sh, mas pode ser executado direto:
#   ./setup.sh [-c /caminho/hosts.csv]

set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
CSV_FILE="$SCRIPT_DIR/data/hosts.csv"
CSV_EXPECTED_COLS=5

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

while getopts "c:" opt; do
  case "$opt" in
  c) CSV_FILE="$OPTARG" ;;
  *) echo "Uso: $0 [-c caminho/hosts.csv]"; exit 1 ;;
  esac
done

if [[ ! -f "$CSV_FILE" ]]; then
  msg_error "Arquivo CSV não encontrado: $CSV_FILE"
  echo "Copie data/hosts.csv.example para data/hosts.csv e preencha com os dados reais," >&2
  echo "ou informe outro caminho com: $0 -c /caminho/hosts.csv" >&2
  exit 1
fi

# Formato do CSV: Host;WG_Port;WG_TunnelIP;OPNsense;URL_BKPRepo
# IP_WAN e a chave WireGuard NÃO ficam no CSV (repo público) -- são sempre
# informados interativamente. URL_BKPRepo pode ficar vazio se OPNsense=n
# ou se não houver backup a restaurar.
if ! csv_validate_columns "$CSV_FILE" "$CSV_EXPECTED_COLS"; then
  msg_error "hosts.csv com linha(s) malformada(s) (colunas != $CSV_EXPECTED_COLS). Corrija antes de continuar:"
  csv_validate_columns "$CSV_FILE" "$CSV_EXPECTED_COLS" >&2 || true
  exit 1
fi

select_host_from_csv() {
  local menu_items=()
  while IFS=';' read -r host _; do
    [[ "$host" == "Host" || -z "$host" ]] && continue
    menu_items+=("$host" "")
  done <"$CSV_FILE"
  menu_items+=("MANUAL" "Configuração avançada (informar manualmente)")

  whiptail --backtitle "UFTM Proxmox Setup" --title "Selecione o Host" \
    --menu "Escolha o host (dados vêm da planilha) ou configure manualmente:" 0 70 12 \
    "${menu_items[@]}" 3>&2 2>&1 1>&3
}

prompt_sensitive_data() {
  UFTM_IP_WAN=$(whiptail --inputbox "IP WAN deste site (deixe vazio se WAN=DHCP/PPPoE):" 0 70 3>&2 2>&1 1>&3) || exit 1

  local WG_MODE
  WG_MODE=$(whiptail --menu "Chave privada WireGuard:" 0 60 2 \
    "informar" "Informar chave existente (padrão)" \
    "gerar" "Gerar novo par com wg genkey" \
    3>&2 2>&1 1>&3) || exit 1

  if [[ "$WG_MODE" == "gerar" ]]; then
    require_cmd wg
    UFTM_WG_PK=$(wg genkey)
    msg_ok "Chave privada gerada (guarde-a; não será exibida novamente)"
  else
    UFTM_WG_PK=$(whiptail --inputbox "Chave privada WireGuard (WG_PK):" 0 70 3>&2 2>&1 1>&3) || exit 1
  fi
}

manual_input() {
  UFTM_HOSTNAME=$(whiptail --inputbox "Hostname base (ex: pve-filial-x):" 0 70 3>&2 2>&1 1>&3) || exit 1
  UFTM_WG_PORT=$(whiptail --inputbox "Porta WireGuard:" 0 70 "51820" 3>&2 2>&1 1>&3) || exit 1
  UFTM_WG_TUNNEL_IP=$(whiptail --inputbox "IP do túnel WireGuard (ex: 10.255.255.X):" 0 70 3>&2 2>&1 1>&3) || exit 1
  UFTM_OPNSENSE=$(whiptail --menu "Instalar VM OPNsense neste site?" 0 60 2 \
    "s" "Sim" "n" "Não" 3>&2 2>&1 1>&3) || exit 1
  UFTM_BKP_URL=""
  if [[ "$UFTM_OPNSENSE" == "s" ]]; then
    UFTM_BKP_URL=$(whiptail --inputbox "URL do config.xml de backup do OPNsense (vazio = instalação limpa):" 0 70 3>&2 2>&1 1>&3) || exit 1
  fi
}

HOST_CHOICE=$(select_host_from_csv) || exit 1

if [[ "$HOST_CHOICE" == "MANUAL" ]]; then
  manual_input
else
  ROW=$(csv_get_row "$CSV_FILE" "$HOST_CHOICE") || { msg_error "Host '$HOST_CHOICE' não encontrado no CSV"; exit 1; }
  IFS=';' read -r UFTM_HOSTNAME UFTM_WG_PORT UFTM_WG_TUNNEL_IP UFTM_OPNSENSE UFTM_BKP_URL <<<"$ROW"
fi

prompt_sensitive_data
UFTM_WG_ENDPOINT="${UFTM_IP_WAN:${UFTM_WG_PORT}}"

# ─────────────────────────────────────────────────────────────
# NÚMERO DE PATRIMÔNIO -> compõe o hostname final (ex: pve-odonto-120699)
# ─────────────────────────────────────────────────────────────
PATRIMONIO=""
while [[ -z "$PATRIMONIO" ]]; do
  PATRIMONIO=$(whiptail --inputbox "Número de patrimônio do PC:" 0 60 3>&2 2>&1 1>&3) || exit 1
  if [[ ! "$PATRIMONIO" =~ ^[0-9]+$ ]]; then
    whiptail --msgbox "O número de patrimônio deve conter apenas dígitos. Tente novamente." 0 0
    PATRIMONIO=""
  fi
done

UFTM_HOSTNAME_FINAL="${UFTM_HOSTNAME}-${PATRIMONIO}"

if whiptail --yesno "O hostname deste host será definido como:\n\n  $UFTM_HOSTNAME_FINAL\n\nConfirma?" 0 0; then
  msg_info "Aplicando hostname $UFTM_HOSTNAME_FINAL"
  OLD_HOSTNAME=$(hostname)
  HOSTFILE=(/etc/hosts /etc/hostname /etc/mailname /etc/postfix/main.cf)
  for f in "${HOSTFILE[@]}"; do
    if grep -q "$OLD_HOSTNAME" "$f" 2>/dev/null; then
      backup_if_exists "$f"
      echo "Alterando arquivo $f"
      echo sed -i "s/${OLD_HOSTNAME}/${UFTM_HOSTNAME_FINAL}/g" "$f"
      sed -i "s/${OLD_HOSTNAME}/${UFTM_HOSTNAME_FINAL}/g" "$f"
    fi
  done
  hostnamectl set-hostname "$UFTM_HOSTNAME_FINAL"
  msg_ok "Hostname aplicado: $UFTM_HOSTNAME_FINAL"
else
  msg_error "Cancelado pelo usuário"
  exit 1
fi

UFTM_HOSTNAME="$UFTM_HOSTNAME_FINAL"

SUMMARY="Host: $UFTM_HOSTNAME
IP WAN: ${UFTM_IP_WAN:-<definido em network-install.sh>}
WG Porta: $UFTM_WG_PORT
WG Tunnel IP: $UFTM_WG_TUNNEL_IP
OPNsense: $UFTM_OPNSENSE
Backup OPNsense: ${UFTM_BKP_URL:-<nenhum>}

Isso vai executar, nesta ordem:
  1) post-install.sh     (otimização do Proxmox)
  2) network-install.sh  (WAN + LAN trunk)
  3) sdn-install.sh      (fabric WireGuard + EVPN + vnets + SNAT)
  4) evpn-bind-vlan.sh   (serviço de bind persistente das VLANs)
  5) opnsense-vm.sh      (se OPNsense = Sim)
  6) reboot (opcional, ao final)

Confirma?"
whiptail --backtitle "UFTM Proxmox Setup" --title "Confirmação" --yesno "$SUMMARY" 0 0 || { msg_error "Cancelado pelo usuário"; exit 1; }

export UFTM_HOSTNAME UFTM_IP_WAN UFTM_WG_ENDPOINT UFTM_WG_PK UFTM_WG_PORT UFTM_WG_TUNNEL_IP UFTM_OPNSENSE UFTM_BKP_URL

run_step() {
  local name="$1" script="$2"
  if [[ -x "$script" ]]; then
    "$script"
  else
    msg_error "$script não encontrado ou sem permissão de execução"
    exit 1
  fi
}

run_step "post-install"    "$BIN_DIR/post-install.sh"
run_step "network-install" "$BIN_DIR/network-install.sh"
run_step "sdn-install"     "$BIN_DIR/sdn-install.sh"
run_step "evpn-bind-vlan"  "$BIN_DIR/evpn-bind-vlan.sh"

if [[ "$UFTM_OPNSENSE" =~ ^[SsYy] ]]; then
  run_step "opnsense-vm" "$BIN_DIR/opnsense-vm.sh"
else
  msg_ok "OPNsense não solicitado para este host"
fi

msg_ok "Setup concluído para $UFTM_HOSTNAME"

if [[ -n "${UFTM_RUN_BACKUP_DIR:-}" ]]; then
  msg_ok "Backups desta execução em: $UFTM_RUN_BACKUP_DIR"
fi

if whiptail --yesno "Setup finalizado. Reiniciar o host agora para aplicar tudo de forma limpa?" 0 0; then
  msg_info "Reiniciando"
  reboot
else
  msg_warn "Reboot adiado -- recomenda-se reiniciar manualmente para validar boot completo (PPPoE, fabric, vnets, VM)."
fi
