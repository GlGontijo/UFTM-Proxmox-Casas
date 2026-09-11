#!/usr/bin/env bash
#
# setup.sh
# Orquestrador principal do UFTM-Proxmox-Casas.
#
# Fluxo (pensado pra instalação em laboratório, sem depender de internet
# depois que a rede final é escrita):
#   0) Desliga o pve-firewall (fica desligado o processo INTEIRO; só volta
#      ligado no fim da etapa 8).
#   1) post-install.sh        - parametriza repositórios e atualiza o sistema
#   2) wizard.sh               - TODO o questionário do projeto, resumível
#   3) download-deps.sh        - todo apt-get/download do projeto (com a
#                                 internet do laboratório ainda de pé)
#   4) network-install.sh      - grava a rede final (WAN/LAN/PPPoE/VLANs) --
#                                 a internet do laboratório pode cair aqui
#   5) hostname-and-restart.sh - aplica hostname, IP de gerência, restart
#                                 de rede + serviços do Proxmox
#   6) sdn-install.sh          - fabric WireGuard + EVPN + vnets + SNAT
#   7) opnsense-vm.sh          - VM OPNsense (se solicitado no wizard)
#   8) pve-firewall-config.sh  - SNMP + Syslog + regras + liga o firewall
#   9) resumo final + reboot opcional
#
# Chamado normalmente pelo bootstrap.sh, mas pode ser executado direto:
#   ./setup.sh [-c /caminho/hosts.csv]

set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

while getopts "c:" opt; do
  case "$opt" in
  c) export UFTM_CSV_FILE="$OPTARG" ;;
  *) echo "Uso: $0 [-c caminho/hosts.csv]"; exit 1 ;;
  esac
done

# ── Etapa 0: firewall desligado durante TODO o processo ────────────
# Só volta a ligar na etapa 8 (pve-firewall-config.sh), depois que todas as
# regras (incluindo os IPs WAN da UFTM coletados no wizard) já estiverem
# escritas de uma vez -- evita ficar aplicando regras parciais no meio do
# processo e travar o próprio acesso ao host.
msg_info "Desligando pve-firewall para todo o processo de instalação"
pve-firewall stop 2>/dev/null || true
msg_ok "pve-firewall desligado (só volta a ligar na etapa 8)"

run_step() {
  local script="$1"
  if [[ -x "$script" ]]; then
    "$script"
  else
    msg_error "$script não encontrado ou sem permissão de execução"
    exit 1
  fi
}

echo ""
echo "════════════════════ ETAPA 1/9: post-install ════════════════════"
run_step "$BIN_DIR/post-install.sh"

echo ""
echo "════════════════════ ETAPA 2/9: wizard ═══════════════════════════"
run_step "$BIN_DIR/wizard.sh"

# A partir daqui, tudo já foi decidido -- carrega o estado gravado pelo wizard.
state_load
: "${UFTM_WIZARD_DONE:?O wizard não foi concluído -- rode de novo}"

echo ""
echo "════════════════════ ETAPA 3/9: download de dependências ════════"
run_step "$BIN_DIR/download-deps.sh"

echo ""
echo "════════════════════ ETAPA 4/9: rede (WAN/LAN/VLANs) ═════════════"
msg_warn "A partir daqui a internet deste laboratório pode cair de propósito."
run_step "$BIN_DIR/network-install.sh"

echo ""
echo "════════════════════ ETAPA 5/9: hostname + restart ═══════════════"
run_step "$BIN_DIR/hostname-and-restart.sh"

echo ""
echo "════════════════════ ETAPA 6/9: SDN (fabric/EVPN/vnets) ══════════"
run_step "$BIN_DIR/sdn-install.sh"
run_step "$BIN_DIR/evpn-bind-vlan.sh"

echo ""
echo "════════════════════ ETAPA 7/9: VM OPNsense ══════════════════════"
if [[ "${UFTM_OPNSENSE:-n}" =~ ^[SsYy] ]]; then
  run_step "$BIN_DIR/opnsense-vm.sh"
else
  msg_ok "OPNsense não solicitado para este host"
fi

echo ""
echo "════════════════════ ETAPA 8/9: firewall ═════════════════════════"
run_step "$BIN_DIR/pve-firewall-config.sh"

echo ""
echo "════════════════════ ETAPA 9/9: resumo final ═════════════════════"
state_load
msg_ok "Setup concluído para ${UFTM_HOSTNAME_FINAL:-$(hostname)}"
if [[ -n "${UFTM_RUN_BACKUP_DIR:-}" ]]; then
  msg_ok "Backups desta execução em: $UFTM_RUN_BACKUP_DIR"
fi

if whiptail --yesno "Setup finalizado. Reiniciar o host agora para validar o boot completo (rede, SDN, VM, firewall)?" 0 0; then
  msg_info "Reiniciando"
  reboot
else
  msg_warn "Reboot adiado -- recomenda-se reiniciar manualmente antes de instalar o PC no cliente final."
fi
