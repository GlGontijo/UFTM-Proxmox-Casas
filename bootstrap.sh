#!/usr/bin/env bash
#
# bootstrap.sh
# Ponto de entrada único do UFTM-Proxmox-Casas.
# Uso remoto (host novo, ainda sem o repo clonado):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/GlGontijo/UFTM-Proxmox-Casas/main/bootstrap.sh)"
# Uso local (repo já clonado):
#   ./bootstrap.sh [-c /caminho/hosts.csv]

set -euo pipefail

REPO_URL="https://github.com/GlGontijo/UFTM-Proxmox-Casas.git"
REPO_DIR="/opt/uftm-proxmox-casas"
BRANCH="main"

RD=$(echo "\033[01;31m"); YW=$(echo "\033[33m"); GN=$(echo "\033[1;92m"); CL=$(echo "\033[m")
msg_info()  { echo -ne " - ${YW}$1...${CL}"; }
msg_ok()    { echo -e "\r \033[K ${GN}✓ $1${CL}"; }
msg_error() { echo -e "\r \033[K ${RD}✗ $1${CL}"; }

if [[ "$(id -u)" -ne 0 ]]; then
  msg_error "Execute como root."
  exit 1
fi

msg_info "Verificando dependências necessárias para o restante do fluxo"
DEPS=(git whiptail wireguard-tools frr ppp pppoe jq curl ethtool bridge-utils tcpdump ipcalc chrony at expect)
MISSING=()
for d in "${DEPS[@]}"; do
  dpkg -s "$d" &>/dev/null || MISSING+=("$d")
done
if [[ "${#MISSING[@]}" -gt 0 ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}"
fi
msg_ok "Dependências ok"

# Se já estamos dentro de um clone do repo (execução local), usa ele.
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

chmod +x "$REPO_DIR"/setup.sh "$REPO_DIR"/bin/*.sh
exec "$REPO_DIR/setup.sh" "$@"
