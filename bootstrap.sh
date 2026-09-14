#!/usr/bin/env bash
#
# bootstrap.sh
# Ponto de entrada único do UFTM-Proxmox-Casas.
# Otimização base do Proxmox VE 9 (Debian 13 / trixie), baseado no fluxo do
# script de comunidade "Proxmox VE Post Install" (community-scripts/ProxmoxVE).
# Idempotente: pode rodar de novo sem duplicar entradas.
#
# Uso remoto (host novo, ainda sem o repo clonado):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/GlGontijo/UFTM-Proxmox-Casas/main/bootstrap.sh)"
# Uso local (repo já clonado):
#   ./bootstrap.sh [-c /caminho/hosts.csv]

set -euo pipefail

REPO_URL="https://github.com/GlGontijo/UFTM-Proxmox-Casas.git"
REPO_DIR="/opt/uftm-proxmox-casas"
BRANCH="main"

RD=$(echo "\033[01;31m"); YW=$(echo "\033[33m"); GN=$(echo "\033[1;92m"); CL=$(echo "\033[m")
msg_info()  { echo -ne " - ${YW}$1...${CL}\n"; }
msg_ok()    { echo -e "\r \033[K ${GN}✓ $1${CL}\n"; }
msg_error() { echo -e "\r \033[K ${RD}✗ $1${CL}\n"; }

if [[ "$(id -u)" -ne 0 ]]; then
  msg_error "Execute como root."
  exit 1
fi

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
msg_info "Versão Proxmox detectada: $PVE_VERSION"
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
msg_info "Nome de versão Debian detectada: $CODENAME"

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
  if grep -q "Components:.*pve-enterprise" "$aptfile" 2>/dev/null; then
    backup_if_exists "$aptfile"
    rm -f "$aptfile"
    msg_ok "Repositório 'pve-enterprise' removido"
  fi
  if grep -q "enterprise.proxmox.com.*ceph" "$aptfile" 2>/dev/null; then
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

# ── 4) Update + upgrade completo (sempre, sem perguntar -- "atualização
#      completa do sistema" é o objetivo desta etapa) ──────────────
msg_info "Atualizando índices de pacotes"
apt-get update -qq
msg_ok "Índices atualizados"

msg_info "Executando dist-upgrade completo (pode demorar)"
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq
msg_ok "Sistema atualizado"

# ── 5) Timezone (aplica direto, sem perguntar) ──────────────────
CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo "?")"
if [[ "$CURRENT_TZ" != "America/Sao_Paulo" ]]; then
  timedatectl set-timezone America/Sao_Paulo
  msg_ok "Timezone ajustado para America/Sao_Paulo (era $CURRENT_TZ)"
else
  msg_ok "Timezone já é America/Sao_Paulo"
fi

# ── 6) high-availability / rrdcached em RAM (evita desgaste do disco) ──
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

msg_ok "Repositórios parametrizados e sistema atualizado"

# ── 7) Dependências para o início da parametrização do host.
msg_info "Verificando dependências (git whiptail)"
DEPS=(git whiptail)
MISSING=()
for d in "${DEPS[@]}"; do
  dpkg -s "$d" &>/dev/null || MISSING+=("$d")
done
if [[ "${#MISSING[@]}" -gt 0 ]]; then
  apt-get install -y -qq "${MISSING[@]}"
fi
msg_ok "Dependências ok"

# ── 8) Se já estamos dentro de um clone do repo (execução local), usa ele.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
if [[ -f "$SCRIPT_DIR/setup.sh" ]]; then
  msg_ok "Executando a partir do clone local em $SCRIPT_DIR"
  exec "$SCRIPT_DIR/setup.sh" "$@"
fi

# Caso contrário, clona/atualiza em $REPO_DIR
if [[ -d "$REPO_DIR/.git" ]]; then
  msg_info "Atualizando repo em $REPO_DIR"
  git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
  git -C "$REPO_DIR" reset --hard --quiet "origin/$BRANCH"
  msg_ok "Repo atualizado"
else
  msg_info "Clonando repo em $REPO_DIR"
  rm -rf "$REPO_DIR"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  msg_ok "Repo clonado"
fi

# ── 9) Inicia o processo de instalação do host
chmod +x "$REPO_DIR"/*.sh "$REPO_DIR"/bin/*.sh
exec "$REPO_DIR/setup.sh" "$@"
