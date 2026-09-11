#!/usr/bin/env bash
#
# bin/pve-firewall-config.sh
# ETAPA 8 do fluxo (última antes do reboot final). O pve-firewall fica
# DESLIGADO durante todo o processo (setup.sh garante isso logo no início) --
# aqui é que a gente escreve TODA a configuração de uma vez (ipset com os
# IPs WAN da UFTM, grupo de regras, SNMP, Syslog) e só então liga o
# firewall de volta.
#
# Os IPs WAN da UFTM nunca são commitados no repositório público -- vêm do
# estado local coletado no wizard (etapa 2) e são escritos direto em
# /etc/pve/firewall/cluster.fw, que não faz parte deste repo Git.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
state_load

: "${UFTM_FW_ALLOWED_IPS:?Rode bin/wizard.sh primeiro (etapa 2) -- IPs autorizados ausentes}"

CLUSTER_FW="/etc/pve/firewall/cluster.fw"
mkdir -p "$(dirname "$CLUSTER_FW")"

# ── 1) SNMP (community DTI, sem restrição de origem no daemon) ──────
msg_info "Configurando snmpd (SNMPv2, community DTI)"
SNMPD_CONF="/etc/snmp/snmpd.conf"
backup_if_exists "$SNMPD_CONF"
cat >"$SNMPD_CONF" <<'EOF'
# Gerado por pve-firewall-config.sh (UFTM-Proxmox-Casas) -- não editar à mão.
# Escuta em todas as interfaces na porta 161 (padrão do Debian restringe a
# 127.0.0.1; aqui abrimos porque o controle de acesso é feito pelo firewall
# do Proxmox, não pelo daemon).
agentAddress udp:161

# Community SNMPv2 somente leitura, sem restrição de origem no próprio
# daemon (aceita de qualquer host que alcance a porta 161).
rocommunity DTI default

sysLocation    UFTM
sysContact     dti@uftm.edu.br
EOF
systemctl enable --now snmpd
systemctl restart snmpd
msg_ok "snmpd configurado (community DTI)"

# ── 2) Syslog remoto para a UFTM ────────────────────────────────────
msg_info "Configurando encaminhamento de Syslog para pgdprotic.uftm.edu.br:1516/udp"
RSYSLOG_CONF="/etc/rsyslog.d/60-uftm-syslog.conf"
backup_if_exists "$RSYSLOG_CONF"
cat >"$RSYSLOG_CONF" <<'EOF'
# Gerado por pve-firewall-config.sh (UFTM-Proxmox-Casas) -- não editar à mão.
# Encaminha todo o log do host via UDP (single @) para o coletor da UFTM.
*.* @pgdprotic.uftm.edu.br:1516
EOF
systemctl restart rsyslog
msg_ok "Syslog remoto configurado"

# ── 3) cluster.fw completo (ipset + regras) ─────────────────────────
msg_info "Gravando $CLUSTER_FW (ipset com os IPs WAN da UFTM + regras padrão)"
backup_if_exists "$CLUSTER_FW"

IPSET_LINES=""
for ip in $UFTM_FW_ALLOWED_IPS; do
  IPSET_LINES+="${ip}"$'\n'
done

cat >"$CLUSTER_FW" <<EOF
[OPTIONS]

enable: 1

[IPSET ipswan-uftm] # Faixas de IPs WAN da UFTM (definidas no wizard, não vão pro Git)

${IPSET_LINES}
[RULES]

GROUP uftm_access # UFTM acesso remoto
IN DHCPfwd(ACCEPT) -log info # DHCP Forward
IN DNS(ACCEPT) -log info # DNS
IN ACCEPT -source +sdn/vnetsnat-all -dest +sdn/vnetsnat-all -log info # SNAT Traffic
IN ACCEPT -i wg0 -log info # Wireguard Interface

[group uftm_access] # Regras para liberação de acesso remoto

IN ACCEPT -source +dc/ipswan-uftm -p udp -dport 51820 -log info # Allow UFTM Access - Wireguard
IN ACCEPT -source +dc/ipswan-uftm -p tcp -dport 8006 -log info # Allow UFTM Access - Proxmox
IN ACCEPT -source +dc/ipswan-uftm -p udp -dport 161 -log info # Allow UFTM Access - SNMP
IN SSH(ACCEPT) -source +dc/ipswan-uftm -log info # Allow UFTM Access - SSH
EOF
msg_ok "cluster.fw gravado (${UFTM_FW_ALLOWED_IPS// / , })"

# ── 4) host.fw (log levels) ──────────────────────────────────────────
HOST_FW_DIR="/etc/pve/firewall"
HOST_FW="$HOST_FW_DIR/$(hostname -s).fw"
if [[ ! -f "$HOST_FW" ]]; then
  cat >"$HOST_FW" <<'EOF'
[OPTIONS]

tcp_flags_log_level: info
log_level_in: info
log_level_forward: info
log_level_out: info
tcpflags: 1
smurf_log_level: info
EOF
  msg_ok "host.fw criado ($HOST_FW)"
fi

# ── 5) Compila e liga o firewall (com rede de segurança) ─────────────
msg_info "Compilando e habilitando o pve-firewall"
echo "pve-firewall stop" | at now + 5 minutes &>/dev/null \
  || msg_warn "'at' não disponível -- pulei a rede de segurança do firewall."

if pve-firewall compile &>/tmp/uftm-fw-compile.log; then
  pve-firewall start
  systemctl enable --now pve-firewall
  msg_ok "Firewall compilado e habilitado"
else
  msg_error "cluster.fw NÃO compilou -- firewall permanece desligado. Log:"
  cat /tmp/uftm-fw-compile.log >&2
  msg_warn "Corrija $CLUSTER_FW manualmente (backup em $UFTM_RUN_BACKUP_DIR) e rode 'pve-firewall compile && pve-firewall start'."
  exit 1
fi

state_mark_step "pve-firewall-config"
msg_ok "pve-firewall-config.sh concluído"
