#!/usr/bin/env bash
#
# bin/download-deps.sh
# ETAPA 3 do fluxo. TUDO que precisa de internet acontece aqui:
#   - todos os apt-get install do projeto inteiro (SDN/FRR/WireGuard/PPPoE/
#     SNMP/Syslog/expect/etc)
#   - download da imagem nano do OPNsense (se selecionado no wizard)
#   - download do backup config.xml (se selecionado no wizard)
#
# A partir da ETAPA 4 (network-install.sh) a conexão com a internet deste
# laboratório é reconfigurada de propósito e pode cair -- por isso nada mais
# pode depender de rede depois deste ponto.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
state_load

: "${UFTM_WIZARD_DONE:?Rode bin/wizard.sh primeiro (etapa 2)}"

mkdir -p "$UFTM_CACHE_DIR"

# ── 1) Teste de conectividade ────────────────────────────────────
msg_info "Testando conexão com a internet"
if ! curl -fsS --max-time 8 -o /dev/null http://download.proxmox.com/; then
  msg_error "Sem conexão com a internet neste momento. Esta etapa PRECISA de internet -- resolva a conectividade do laboratório antes de continuar."
  exit 1
fi
msg_ok "Internet ok"

# ── 2) Pacotes apt necessários para TODO o projeto ───────────────
APT_PKGS=(
  wireguard-tools frr frr-pythontools libpve-network-perl
  ppp pppoe
  jq curl ethtool bridge-utils tcpdump ipcalc chrony at expect
  snmpd snmp
  rsyslog rsyslog-doc rsyslog-snmp
)

msg_info "Calculando o que falta instalar"
MISSING=()
for p in "${APT_PKGS[@]}"; do
  dpkg -s "$p" &>/dev/null || MISSING+=("$p")
done

if [[ "${#MISSING[@]}" -eq 0 ]]; then
  msg_ok "Todos os pacotes já estão instalados"
else
  apt-get update -qq
  # Estimativa de tamanho via --simulate/-s, só informativo
  SIM_OUT=$(apt-get install -s "${MISSING[@]}" 2>/dev/null | grep -E "^Need to get|^Inst " || true)
  SIZE_LINE=$(echo "$SIM_OUT" | grep "^Need to get" || echo "Need to get: tamanho não determinado")
  whiptail --msgbox "Pacotes a instalar (${#MISSING[@]}): ${MISSING[*]}\n\n$SIZE_LINE" 0 78

  TOTAL="${#MISSING[@]}"
  {
    for i in "${!MISSING[@]}"; do
      pkg="${MISSING[$i]}"
      echo "XXX"
      echo $(( (i) * 100 / TOTAL ))
      echo "Instalando $pkg ($((i + 1))/$TOTAL)..."
      echo "XXX"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" || true
    done
    echo "XXX"; echo 100; echo "Concluído"; echo "XXX"
  } | whiptail --gauge "Instalando dependências do projeto..." 8 70 0

  # Confirma o que realmente ficou faltando (apt pode ter falhado silenciosamente)
  STILL_MISSING=()
  for p in "${MISSING[@]}"; do
    dpkg -s "$p" &>/dev/null || STILL_MISSING+=("$p")
  done
  if [[ "${#STILL_MISSING[@]}" -gt 0 ]]; then
    msg_error "Não instalaram: ${STILL_MISSING[*]} -- verifique manualmente antes de continuar."
    exit 1
  fi
  msg_ok "Pacotes instalados"
fi

systemctl enable --now atd 2>/dev/null || true

# ── 3) Imagem OPNsense (nano) -- só se o wizard pediu OPNsense ───
if [[ "${UFTM_OPNSENSE:-n}" =~ ^[SsYy] ]]; then
  OPN_VER="${UFTM_OPN_VER:-26.7}"
  MIRROR_URL="https://pkg.opnsense.org/releases"
  IMG_NAME="OPNsense-${OPN_VER}-nano-amd64.img"
  IMG_PATH="$UFTM_CACHE_DIR/$IMG_NAME"

  msg_info "Verificando/baixando imagem OPNsense $OPN_VER (nano)"
  cd "$UFTM_CACHE_DIR"
  MAX_ATTEMPTS=5
  ATTEMPT=1
  while true; do
    if [[ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]]; then
      msg_error "Número máximo de tentativas ($MAX_ATTEMPTS) atingido ao baixar a imagem OPNsense."
      exit 1
    fi
    [[ -f checksums.sha256 ]] || wget -q -O checksums.sha256 \
      "${MIRROR_URL}/${OPN_VER}/OPNsense-${OPN_VER}-checksums-amd64.sha256" || true

    if [[ -f "${IMG_PATH}.bz2" ]] && file "${IMG_PATH}.bz2" | grep -q "bzip2 compressed data"; then
      EXPECTED_HASH=$(grep -F "${IMG_NAME}.bz2" checksums.sha256 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
      LOCAL_HASH=$(sha256sum "${IMG_PATH}.bz2" 2>/dev/null | awk '{print $1}' | tr -d ' \r\n')
      if [[ -n "$EXPECTED_HASH" && "$EXPECTED_HASH" == "$LOCAL_HASH" ]]; then
        msg_ok "Imagem já em cache e íntegra ($UFTM_CACHE_DIR)"
        break
      fi
      msg_warn "Checksum divergente/incompleto -- rebaixando"
      rm -f "${IMG_PATH}.bz2"
    fi

    echo "Baixando ${IMG_NAME}.bz2 ..."
    wget -c --progress=bar:force -O "${IMG_PATH}.bz2" "${MIRROR_URL}/${OPN_VER}/${IMG_NAME}.bz2" 2>&1 | tail -n 20 || true
    ATTEMPT=$((ATTEMPT + 1))
  done

  if [[ ! -f "$IMG_PATH" ]]; then
    msg_info "Descomprimindo a imagem"
    bunzip2 -k -f "${IMG_PATH}.bz2"
  fi
  msg_ok "Imagem OPNsense pronta em $IMG_PATH"
  state_set UFTM_OPN_IMG_PATH "$IMG_PATH"

  # ── 4) Backup config.xml (se selecionado no wizard) ────────────
  if [[ "${UFTM_OPN_BKP_MODE:-none}" != "none" ]]; then
    CONFIG_LOCAL="$UFTM_CACHE_DIR/config.xml"
    URL="${UFTM_OPN_BKP_URL:-}"

    if [[ "${UFTM_OPN_BKP_MODE}" == "local" ]]; then
      if [[ -d "$URL" ]]; then
        mapfile -t XML_FILES < <(find "$URL" -maxdepth 1 -type f -iname '*.xml' | sort -r)
        if [[ "${#XML_FILES[@]}" -eq 0 ]]; then
          msg_error "Nenhum .xml em $URL"
        else
          MENU_ITEMS=(); i=0
          for f in "${XML_FILES[@]}"; do MENU_ITEMS+=("$i" "$(basename "$f")"); i=$((i + 1)); done
          IDX=$(whiptail --menu "Selecione o backup ($URL):" 0 78 12 "${MENU_ITEMS[@]}" 3>&2 2>&1 1>&3) || true
          [[ -n "${IDX:-}" ]] && cp "${XML_FILES[$IDX]}" "$CONFIG_LOCAL"
        fi
      elif [[ -f "$URL" ]]; then
        cp "$URL" "$CONFIG_LOCAL"
      fi
    elif [[ "$URL" == *github.com/* || "$URL" == *api.github.com/repos/* ]]; then
      require_cmd curl jq
      GH_TOKEN=$(whiptail --passwordbox "Personal Access Token do GitHub (escopo 'repo', leitura basta) -- não fica salvo:" 0 70 3>&2 2>&1 1>&3) || true
      if [[ -n "${GH_TOKEN:-}" ]]; then
        read -r GH_MODE GH_OWNER GH_REPO GH_BRANCH GH_PATH <<<"$(python3 - "$URL" <<'PYEOF'
import re, sys
url = sys.argv[1]
m = re.match(r'https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/?(.*)$', url)
if m:
    o, r, b, p = m.groups(); print("tree", o, r.removesuffix(".git"), b, p or "-"); sys.exit()
m = re.match(r'https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$', url)
if m:
    o, r, b, p = m.groups(); print("blob", o, r.removesuffix(".git"), b, p); sys.exit()
m = re.match(r'https?://api\.github\.com/repos/([^/]+)/([^/]+)/contents/?([^?]*)\??(?:ref=(.+))?$', url)
if m:
    o, r, p, b = m.groups(); print("tree", o, r, b or "main", p or "-"); sys.exit()
m = re.match(r'https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$', url)
if m:
    o, r = m.groups(); print("tree", o, r, "main", "-"); sys.exit()
print("unknown", "", "", "", "")
PYEOF
)"
        [[ "$GH_PATH" == "-" ]] && GH_PATH=""
        gh_api_download() {
          local api_path="$1" outfile="$2" accept="${3:-application/vnd.github+json}"
          curl -sS -o "$outfile" -w '%{http_code}' \
            -H "Authorization: token ${GH_TOKEN}" -H "Accept: ${accept}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/contents/${api_path}?ref=${GH_BRANCH}"
        }
        if [[ "$GH_MODE" == "blob" ]]; then
          HTTP_CODE=$(gh_api_download "$GH_PATH" "$CONFIG_LOCAL" "application/vnd.github.v3.raw")
          [[ "$HTTP_CODE" != "200" ]] && { msg_error "GitHub HTTP $HTTP_CODE"; rm -f "$CONFIG_LOCAL"; }
        elif [[ "$GH_MODE" == "tree" ]]; then
          LISTING_JSON="/tmp/uftm-gh-listing.json"
          HTTP_CODE=$(gh_api_download "$GH_PATH" "$LISTING_JSON")
          if [[ "$HTTP_CODE" == "200" ]]; then
            mapfile -t XML_NAMES < <(jq -r '.[] | select(.type=="file") | select(.name | test("\\.xml$"; "i")) | .name' "$LISTING_JSON" | sort -r)
            rm -f "$LISTING_JSON"
            if [[ "${#XML_NAMES[@]}" -gt 0 ]]; then
              MENU_ITEMS=(); i=0
              for n in "${XML_NAMES[@]}"; do MENU_ITEMS+=("$i" "$n"); i=$((i + 1)); done
              IDX=$(whiptail --menu "Selecione o backup (${GH_OWNER}/${GH_REPO}@${GH_BRANCH}):" 0 78 12 "${MENU_ITEMS[@]}" 3>&2 2>&1 1>&3) || true
              if [[ -n "${IDX:-}" ]]; then
                SELECTED_PATH="${GH_PATH:+${GH_PATH}/}${XML_NAMES[$IDX]}"
                HTTP_CODE=$(gh_api_download "$SELECTED_PATH" "$CONFIG_LOCAL" "application/vnd.github.v3.raw")
                [[ "$HTTP_CODE" != "200" ]] && { msg_error "Falha ao baixar (HTTP $HTTP_CODE)"; rm -f "$CONFIG_LOCAL"; }
              fi
            else
              msg_error "Nenhum .xml encontrado em ${GH_PATH:-/}"
            fi
          else
            msg_error "GitHub HTTP $HTTP_CODE ao listar"
          fi
        else
          msg_error "URL do GitHub não reconhecida: $URL"
        fi
      fi
      unset GH_TOKEN
    elif [[ "${URL,,}" == *.xml ]]; then
      wget -q -O "$CONFIG_LOCAL" "$URL" || msg_error "Falha ao baixar $URL"
    fi

    if [[ -f "$CONFIG_LOCAL" ]]; then
      msg_ok "config.xml em cache: $CONFIG_LOCAL"
      state_set UFTM_OPN_CONFIG_XML_PATH "$CONFIG_LOCAL"
    else
      msg_warn "Backup do OPNsense não foi baixado -- opnsense-vm.sh vai fazer instalação limpa."
    fi
  fi
fi

state_mark_step "download-deps"
msg_ok "download-deps.sh concluído -- a partir daqui, a internet deste laboratório pode ser perdida sem problema."
