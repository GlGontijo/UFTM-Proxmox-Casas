#!/usr/bin/env bash
#
# bin/post-install.sh
# Otimização base do Proxmox VE 9 (Debian 13 / trixie), baseado no fluxo do
# script de comunidade "Proxmox VE Post Install" (community-scripts/ProxmoxVE).
# Idempotente: pode rodar de novo sem duplicar entradas.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

PVE_VERSION="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
IFS='.' read -r PVE_MAJOR PVE_MINOR _ <<<"$(echo "$PVE_VERSION")"

PVE_SOURCES="/etc/apt/sources.list.d/pve-enterprise.sources"
PVE_NOSUB="/etc/apt/sources.list.d/pve-no-subscription.sources"
CEPH_SOURCES="/etc/apt/sources.list.d/ceph.sources"
DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
if ((PVE_MINOR >= 2)); then
  CEPH_RELEASE="ceph-tentacle"
else
  CEPH_RELEASE="ceph-squid"
fi
TEST_SOURCES="/etc/apt/sources.list.d/pve-test.sources"

# __ Confere se a versão é suportada
msg_ok "Versão Proxmox detectada: $PVE_VERSION"
if [[ "$PVE_MAJOR" == "9" ]]; then
  if ((PVE_MINOR < 0 || PVE_MINOR > 2)); then
    msg_error "Somente Proxmox 9.0-9.2.x é atualmente suportada"
    exit 105
  fi
  msg_ok "Versão do Proxmox é suportada. Seguindo com a instalação..."
else
  msg_error "Somente Proxmox 9.0-9.2.x é atualmente suportada"
  exit 105
fi

# ── Detecta codename (trixie no PVE 9) ─────────────────────────
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
msg_ok "Versão Debian detectada: $CODENAME"

# ── 1) Repositório Debian correto (main/updates/security) ─────
msg_info "Configurando repositórios Debian ($CODENAME)"
backup_if_exists "$DEBIAN_SOURCES"
cat >"$DEBIAN_SOURCES" <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $CODENAME
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $CODENAME-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: $CODENAME-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
msg_ok "Repositórios Debian configurados"

# ── 2) Desabilita enterprise repo, habilita no-subscription ────
msg_info "Ajustando repositórios Proxmox VE"
for aptfile in /etc/apt/sources.list.d/*.sources; do
  msg_info "Removendo repositórios '*-enterprise'..."
  if grep -q "Components:.*pve-enterprise" "$aptfile"; then
    backup_if_exists "$aptfile"
    rm -f "$aptfile"
    msg_ok "Repositório 'pve-enterprise' removido"
  fi
  if grep -q "enterprise.proxmox.com.*ceph" "$aptfile"; then
    backup_if_exists "$aptfile"
    rm -f "$aptfile"
    msg_ok "Repositório 'ceph-enterprise' removido"
  fi
done

cat >"$PVE_NOSUB" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $CODENAME
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
msg_ok "Repositório no-subscription habilitado"

msg_info "Adicionando repositório 'ceph no-subscription' (deb822)"
cat >"$CEPH_SOURCES" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/${CEPH_RELEASE}
Suites: $CODENAME
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF
msg_ok "Repositório 'ceph no-subscription' (${CEPH_RELEASE}) adicionado, mas desabilitado. Caso seja necessário o uso, habilitar via web"

msg_info "Adicionando repositório 'pve-test' (deb822, disabled)"
cat >"$TEST_SOURCES" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $CODENAME
Components: pve-test
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF
msg_ok "Repositório 'pve-test' adicionado, mas desabilitado. Caso seja necessário o uso, habilitar via web"

# ── 3) Remove nag de assinatura na UI ───────────────────────────
msg_info "Removendo aviso de assinatura na Web UI"
JS_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
APT_HOOK="/etc/apt/apt.conf.d/no-nag-script"
if [[ -f "$JS_FILE" ]] && ! grep -q "NoMoreNagging" "$JS_FILE"; then
  backup_if_exists "$JS_FILE"
  sed -i.bak 's/res\[0\]\[.status.\] !== .Active./false/g' "$JS_FILE" || true
fi
cat >"$APT_HOOK" <<'EOF'
DPkg::Post-Invoke { "dpkg -l proxmox-widget-toolkit >/dev/null 2>&1 && sed -i.bak 's/res\[0\]\[.status.\] !== .Active./false/g' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js || true"; };
EOF
msg_ok "Nag removido (e reaplicação automática registrada em apt hook)"

# ── 4) Update + upgrade ────────────────────────────────────────
msg_info "Atualizando índices de pacotes"
apt-get update -qq
msg_ok "Índices atualizados"

if whiptail --yesno "Executar 'apt-get dist-upgrade' agora? (recomendado antes de prosseguir)" 0 0; then
  msg_info "Executando dist-upgrade (pode demorar)"
  DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq
  msg_ok "Sistema atualizado"
else
  msg_warn "Upgrade pulado a pedido do usuário"
fi

# ── 5) Pacotes úteis para o restante do fluxo ──────────────────
msg_info "Instalando pacotes base (wireguard-tools, frr, ppp, rp-pppoe, jq, curl, ethtool, at)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  wireguard-tools frr ppp pppoe jq curl ethtool bridge-utils tcpdump ipcalc chrony at
systemctl enable --now atd 2>/dev/null || true
msg_ok "Pacotes base instalados"

# ── 6) Timezone e locale (não força, só avisa se diferente) ────
CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo "?")"
if [[ "$CURRENT_TZ" != "America/Sao_Paulo" ]]; then
  if whiptail --yesno "Timezone atual: $CURRENT_TZ. Ajustar para America/Sao_Paulo?" 0 0; then
    timedatectl set-timezone America/Sao_Paulo
    msg_ok "Timezone ajustado para America/Sao_Paulo"
  fi
fi

# ── 7) high-availability / rrdcached em RAM (evita desgaste do disco) ──
msg_info "Ajustando rrdcached para reduzir I/O em disco"
mkdir -p /etc/systemd/system/rrdcached.service.d
cat >/etc/systemd/system/rrdcached.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/rrdcached -B -b /var/lib/rrdcached/db/ -j /var/lib/rrdcached/journal/ -p /var/run/rrdcached.pid -F -w 300 -z 300
EOF
systemctl daemon-reload
systemctl restart rrdcached 2>/dev/null || true
msg_ok "rrdcached ajustado (flush a cada 300s)"

# ── 8) SNMP (monitoramento DTI) + Syslog remoto para a UFTM ─────
# SNMPv2 (community "DTI", sem restrição de origem no daemon -- o controle
# de quem alcança a porta fica por conta do firewall) e encaminhamento de
# todo o log do host via syslog UDP para pgdprotic.uftm.edu.br:1516.
if whiptail --yesno "Configurar SNMP (community DTI) e encaminhamento de Syslog para a UFTM agora?" 0 0; then

  # -- SNMPv2 --------------------------------------------------------
  msg_info "Instalando e configurando snmpd (SNMPv2, community DTI)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq snmpd snmp
  SNMPD_CONF="/etc/snmp/snmpd.conf"
  backup_if_exists "$SNMPD_CONF"
  cat >"$SNMPD_CONF" <<'EOF'
# Gerado por post-install.sh (UFTM-Proxmox-Casas) -- não editar à mão.
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
  msg_ok "snmpd configurado (community DTI, aceitando de qualquer origem no daemon)"

  # -- Firewall: libera 161/udp no mesmo grupo da WAN UFTM ------------
  msg_info "Liberando UDP/161 no firewall (grupo uftm_access, mesma faixa da WAN UFTM)"
  CLUSTER_FW="/etc/pve/firewall/cluster.fw"
  if [[ -f "$CLUSTER_FW" ]]; then
    backup_if_exists "$CLUSTER_FW"
    if python3 - "$CLUSTER_FW" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()

RULE = "IN ACCEPT -source +dc/ipswan-uftm -p udp -dport 161 -log info # Allow UFTM Access - SNMP\n"

# já existe? (idempotente)
if any("SNMP" in l and "161" in l for l in lines):
    print("  (regra de SNMP já presente, nada a fazer)")
    sys.exit(0)

out = []
inserted = False
in_group = False
for line in lines:
    out.append(line)
    if re.match(r'^\[group uftm_access\]', line.strip()):
        in_group = True
        continue
    if in_group and not inserted:
        # insere logo após a linha de comentário do grupo (ou na primeira linha em branco/regra)
        if line.strip().startswith('#') or line.strip() == '':
            continue
        # insere ANTES da primeira regra "de verdade" do grupo, mantendo o padrão
        out.insert(len(out) - 1, RULE)
        inserted = True

if not inserted:
    print("  [AVISO] Seção [group uftm_access] não encontrada -- regra NÃO inserida. Adicione manualmente.")
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
print("  + regra de SNMP (UDP/161) adicionada ao grupo uftm_access")
PYEOF
    then
      PY_RC=0
    else
      PY_RC=$?
    fi
    if [[ "$PY_RC" -eq 0 ]]; then
      # Rede de segurança: se a regra sair errada e travar o acesso, o
      # firewall do PVE é desligado sozinho em 5 minutos.
      echo "pve-firewall stop" | at now + 5 minutes &>/dev/null || msg_warn "'at' não disponível -- pulei a rede de segurança do firewall (instale 'at' para tê-la)."
      if pve-firewall compile &>/tmp/uftm-fw-compile.log; then
        pve-firewall restart
        msg_ok "Firewall recarregado com a regra de SNMP (UDP/161, mesma faixa da WAN UFTM)"
      else
        msg_error "cluster.fw não compilou -- restaure o backup em $UFTM_RUN_BACKUP_DIR e revise manualmente."
        cat /tmp/uftm-fw-compile.log >&2
      fi
    else
      msg_warn "Não consegui inserir a regra automaticamente -- adicione manualmente em $CLUSTER_FW, seção [group uftm_access]:"
      msg_warn "  IN ACCEPT -source +dc/ipswan-uftm -p udp -dport 161 -log info # Allow UFTM Access - SNMP"
    fi
  else
    msg_warn "$CLUSTER_FW não encontrado -- pulei a liberação de firewall (crie o grupo uftm_access manualmente se necessário)."
  fi

  # -- Syslog remoto ---------------------------------------------------
  msg_info "Instalando e configurando encaminhamento de Syslog para pgdprotic.uftm.edu.br:1516/udp"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsyslog rsyslog-doc rsyslog-snmp
  RSYSLOG_CONF="/etc/rsyslog.d/60-uftm-syslog.conf"
  backup_if_exists "$RSYSLOG_CONF"
  cat >"$RSYSLOG_CONF" <<'EOF'
# Gerado por post-install.sh (UFTM-Proxmox-Casas) -- não editar à mão.
# Encaminha todo o log do host via UDP (single @) para o coletor da UFTM.
*.* @pgdprotic.uftm.edu.br:1516
EOF
  systemctl restart rsyslog
  msg_ok "Syslog remoto configurado (UDP, pgdprotic.uftm.edu.br:1516)"
else
  msg_warn "SNMP/Syslog pulados a pedido do usuário -- rode post-install.sh de novo para configurar depois."
fi

msg_ok "post-install.sh concluído"
