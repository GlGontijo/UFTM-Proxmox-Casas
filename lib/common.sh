#!/usr/bin/env bash
# lib/common.sh
# Funções compartilhadas por todos os scripts do UFTM-Proxmox-Casas.
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

RD=$(echo "\033[01;31m"); YW=$(echo "\033[33m"); GN=$(echo "\033[1;92m"); CL=$(echo "\033[m")
BFR="\\r\\033[K"; HOLD="-"; CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"

msg_info()  { echo -ne " ${HOLD} ${YW}$1...\n"; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}$1${CL}\n"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}$1${CL}\n"; }
msg_warn()  { echo -e " ${YW}⚠ $1${CL}\n"; }

UFTM_ETC_DIR="/etc/uftm-proxmox-casas"
UFTM_BACKUP_ROOT="/root/uftm-proxmox-casas-backups"
UFTM_CACHE_DIR="/root/uftm-proxmox-casas-cache"
UFTM_STATE_FILE="$UFTM_ETC_DIR/wizard-state.env"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Este script precisa ser executado como root."
    exit 1
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" &>/dev/null || { msg_error "Comando obrigatório não encontrado: $c"; exit 1; }
  done
}

# backup_if_exists <arquivo>
# Copia o arquivo (se existir) para $UFTM_BACKUP_ROOT/<timestamp-do-run>/<basename>.bak
# Usa a variável UFTM_RUN_BACKUP_DIR se já foi definida nesta execução (evita
# criar um diretório novo por chamada), senão cria uma.
backup_if_exists() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  : "${UFTM_RUN_BACKUP_DIR:=$UFTM_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)}"
  export UFTM_RUN_BACKUP_DIR
  mkdir -p "$UFTM_RUN_BACKUP_DIR"
  # preserva a árvore de diretórios dentro do backup, útil pra restaurar depois
  local dest="$UFTM_RUN_BACKUP_DIR${f}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
}

# csv_get_row <csv_file> <host> -> imprime a linha (sem o header) ou falha
csv_get_row() {
  local csv="$1" host="$2"
  awk -F';' -v h="$host" 'NR==1{next} $1==h{print; found=1} END{exit !found}' "$csv"
}

# csv_validate_columns <csv_file> <n_esperado>
# Garante que toda linha de dados tem exatamente N campos (detecta linhas
# truncadas como a do bug do WG_Port ausente).
csv_validate_columns() {
  local csv="$1" expected="$2"
  awk -F';' -v cols="$expected" 'NR==1{next} /^[ \t\r]*$/{next} NF!=cols{printf "Linha %d tem %d campos (esperado %d): %s\n", NR, NF, cols, $0; bad=1} END{if(bad==1) exit 1; else exit 0}' "$csv"
}

# is_valid_ipv4 <ip>
is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  for o in ${ip//./ }; do (( o >= 0 && o <= 255 )) || return 1; done
  return 0
}

pause_ack() {
  whiptail --msgbox "$1" 0 70
}

# ── Estado do wizard (arquivo único, resumível) ─────────────────────
# Todo o questionário roda em bin/wizard.sh e grava um KEY=VALUE por linha
# em $UFTM_STATE_FILE. As demais fases (network-install, sdn-install,
# hostname-and-restart, opnsense-vm, pve-firewall-config) só LEEM esse
# arquivo -- nenhuma delas pergunta nada ao usuário diretamente.

state_load() {
  msg_info "Verifica se o processo foi interrompido"
  [[ -f "$UFTM_STATE_FILE" ]] && source "$UFTM_STATE_FILE"
}

# state_set <NOME_DA_VAR> <valor>
# Grava/atualiza uma variável no arquivo de estado de forma idempotente
# (não duplica a linha se rodar de novo) e já exporta na sessão atual.
state_set() {
  local name="$1" value="$2"
  mkdir -p "$UFTM_ETC_DIR"
  touch "$UFTM_STATE_FILE"
  chmod 600 "$UFTM_STATE_FILE"
  local esc_value
  printf -v esc_value '%q' "$value"
  if grep -q "^${name}=" "$UFTM_STATE_FILE" 2>/dev/null; then
    sed -i "s|^${name}=.*|${name}=${esc_value}|" "$UFTM_STATE_FILE"
  else
    echo "${name}=${esc_value}" >>"$UFTM_STATE_FILE"
  fi
  export "${name}=${value}"
}

# state_mark_step <nome_da_etapa>
# Registra que uma etapa do wizard/setup foi concluída (para retomar um
# processo interrompido sem repetir o que já foi feito).
state_mark_step() {
  state_set "UFTM_STEP_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')_DONE" "1"
}

# state_step_done <nome_da_etapa> -> 0 (feito) / 1 (não feito)
state_step_done() {
  local var="UFTM_STEP_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')_DONE"
  [[ "${!var:-0}" == "1" ]]
}
