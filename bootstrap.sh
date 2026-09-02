#!/usr/bin/env bash
#
# bootstrap.sh
# Clona (ou atualiza) o repositório público UFTM-Proxmox-Casas via HTTPS
# e executa o setup.sh principal.
#
# Uso (primeira execução num host novo, um comando só):
#   bash <(curl -fsSL https://raw.githubusercontent.com/GlGontijo/UFTM-Proxmox-Casas/main/bootstrap.sh)
#
# Uso local (host já com o repo clonado):
#   bash bootstrap.sh
#
# Para fixar uma versão/tag específica em vez de sempre pegar o
# branch main (recomendado em produção, para reprodutibilidade):
#   UFTM_BRANCH=v1.0 bash <(curl -fsSL https://raw.githubusercontent.com/.../bootstrap.sh)

set -euo pipefail

REPO_HTTPS_URL="https://github.com/GlGontijo/UFTM-Proxmox-Casas.git"
REPO_DIR="/opt/uftm-proxmox"
REPO_BRANCH="${UFTM_BRANCH:-main}"   # permite fixar versão via env var

msg() { echo -e "\033[33m[bootstrap]\033[0m $1"; }

# ─────────────────────────────────────────────────────────────
# Clone ou atualização
# ─────────────────────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
  msg "Repositório já existe em $REPO_DIR, atualizando..."
  git -C "$REPO_DIR" fetch origin
  git -C "$REPO_DIR" checkout "$REPO_BRANCH"
  git -C "$REPO_DIR" pull origin "$REPO_BRANCH"
else
  msg "Clonando repositório em $REPO_DIR..."
  git clone --branch "$REPO_BRANCH" "$REPO_HTTPS_URL" "$REPO_DIR"
fi

chmod +x "$REPO_DIR"/bin/*.sh "$REPO_DIR"/setup.sh 2>/dev/null || true

cd "$REPO_DIR"
exec ./setup.sh "$@"
