#!/usr/bin/env bash
#
# bootstrap.sh
# Clona (ou atualiza) o repositório privado UFTM-Proxmox-Casas via SSH
# e executa o setup.sh principal.
#
# Uso local (host já com o repo clonado ou chave configurada):
#   bash bootstrap.sh
#
# Uso remoto (primeira execução num host novo, com a chave SSH já
# configurada — ver seção de pré-requisitos abaixo):
#   bash <(curl -fsSL https://raw.githubusercontent.com/.../bootstrap.sh)
#
# ATENÇÃO: como o repo é privado, o comando acima só funciona se o
# raw.githubusercontent.com permitir acesso ao arquivo bootstrap.sh
# sem autenticação -- o que só é possível se ESSE ARQUIVO ESPECÍFICO
# estiver em um repo público, ou se você usar um token/curl -H
# "Authorization: token ..." apontando pra api.github.com em vez de
# raw.githubusercontent.com. Ver observações no final da mensagem.

set -euo pipefail

REPO_SSH_URL="git@github.com:GlGontijo/UFTM-Proxmox-Casas.git"
REPO_DIR="/opt/uftm-proxmox"
REPO_BRANCH="${UFTM_BRANCH:-main}"   # permite fixar versão via env var

msg() { echo -e "\033[33m[bootstrap]\033[0m $1"; }

# ─────────────────────────────────────────────────────────────
# Pré-requisitos: chave SSH com acesso de leitura ao repo
# ─────────────────────────────────────────────────────────────
if ! ssh -T git@github.com -o StrictHostKeyChecking=accept-new 2>&1 | grep -qi "success"; then
  echo "ERRO: não foi possível autenticar no GitHub via SSH." >&2
  echo "Verifique se este host tem uma chave SSH (deploy key) com" >&2
  echo "acesso de leitura ao repositório GlGontijo/UFTM-Proxmox-Casas," >&2
  echo "e se ela está carregada no ssh-agent ou em ~/.ssh/id_ed25519." >&2
  exit 1
fi

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
  git clone --branch "$REPO_BRANCH" "$REPO_SSH_URL" "$REPO_DIR"
fi

chmod +x "$REPO_DIR"/bin/*.sh "$REPO_DIR"/setup.sh 2>/dev/null || true

cd "$REPO_DIR"
exec ./setup.sh "$@"
