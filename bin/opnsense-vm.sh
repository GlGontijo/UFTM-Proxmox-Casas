#!/usr/bin/env bash
#
# bin/opnsense-vm.sh
# Criação e automação de VM OPNsense (imagem "nano") no Proxmox VE.
# Baseado no script original do projeto (download com resume+checksum da
# imagem nano oficial, criação da VM, importação/expansão do disco e
# automação do primeiro boot via console serial com `expect`).
#
# Adaptado aqui para:
#   - padrão whiptail/msg_* do restante do repo
#   - VMID/bridges dinâmicos (lidos de network.env / hosts.csv em vez de
#     valores fixos no topo do script)
#   - opção de restaurar config.xml de backup (URL do hosts.csv ou arquivo
#     local), aplicado DEPOIS do primeiro boot via `fetch` dentro do próprio
#     OPNsense (evita mexer no disco/UFS pelo lado do host Proxmox)
#
# BUG CORRIGIDO em relação à versão anterior: as respostas do wizard para
# "Enter the WAN/LAN interface name" estavam como vnet0/vnet1 -- interfaces
# virtio no FreeBSD aparecem como vtnet0/vtnet1. Corrigido abaixo.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_cmd qm wget bunzip2 sha256sum file

[[ -f "$UFTM_ETC_DIR/network.env" ]] && source "$UFTM_ETC_DIR/network.env"
: "${UFTM_LAN_BRIDGE:?rode network-install.sh antes (bridge de trunk da LAN não definida)}"

if ! command -v expect &>/dev/null; then
  msg_info "Instalando dependência 'expect'"
  apt-get update -qq && apt-get install -y -qq expect
  msg_ok "'expect' instalado"
fi

# ── Parâmetros (com defaults, todos editáveis via whiptail) ────────
DEFAULT_VMID=100
STORAGE=$(whiptail --inputbox "Storage para o disco da VM:" 0 60 "local-lvm" 3>&2 2>&1 1>&3) || exit 1
BRIDGE_WAN="vnetsnat"
BRIDGE_LAN=$(whiptail --inputbox "Bridge para a LAN (trunk):" 0 60 "$UFTM_LAN_BRIDGE" 3>&2 2>&1 1>&3) || exit 1
CPU_CORES=$(whiptail --inputbox "vCPUs:" 0 50 "2" 3>&2 2>&1 1>&3) || exit 1
RAM_MB=$(whiptail --inputbox "RAM (MB):" 0 50 "4096" 3>&2 2>&1 1>&3) || exit 1
DISK_EXPAND=$(whiptail --inputbox "Expandir disco para (ex: 200G):" 0 50 "200G" 3>&2 2>&1 1>&3) || exit 1
OPNSENSE_VER=$(whiptail --inputbox "Versão do OPNsense:" 0 50 "26.7" 3>&2 2>&1 1>&3) || exit 1
MIRROR_URL="https://pkg.opnsense.org/releases"
IMG_NAME="OPNsense-${OPNSENSE_VER}-nano-amd64.img"

# ── Nome da VM a partir do hostname do Proxmox ──────────────────
PROXMOX_HOST="${UFTM_HOSTNAME:-$(hostname -s)}"
SUFFIX="${PROXMOX_HOST#pve-}"; SUFFIX="${SUFFIX#PVE-}"
VM_NAME="opnsense-${SUFFIX}"
VM_NAME=$(echo "$VM_NAME" | tr '[:upper:]' '[:lower:]')

# ── VMID: 100 por padrão; se já existir, excluir/recriar ou usar o próximo livre ──
VMID="$DEFAULT_VMID"
while qm status "$VMID" &>/dev/null; do
  if whiptail --yesno "Já existe uma VM com ID $VMID.\nExcluir e recriar?" 0 0; then
    msg_info "Removendo VM $VMID existente"
    qm stop "$VMID" --skiplock 1 &>/dev/null || true
    qm destroy "$VMID" --purge 1 &>/dev/null
    msg_ok "VM $VMID removida"
    break
  else
    VMID=$((VMID + 1))
  fi
done

whiptail --msgbox "Host Proxmox: $PROXMOX_HOST
Nome da VM:   $VM_NAME
VM ID:        $VMID
WAN:          net0 -> $BRIDGE_WAN
LAN:          net1 -> $BRIDGE_LAN
CPU/RAM:      $CPU_CORES vCPU / ${RAM_MB}MB
Disco:        $STORAGE, expandido para $DISK_EXPAND
Versão:       OPNsense $OPNSENSE_VER (nano)" 0 70

# ── 1) Download com resume + validação de checksum ──────────────
TEMP_DIR="/tmp/opnsense_deploy_${VMID}"
mkdir -p "$TEMP_DIR"; cd "$TEMP_DIR"

MAX_ATTEMPTS=5
ATTEMPT=1
msg_info "Baixando/validando imagem OPNsense $OPNSENSE_VER (nano)"
while true; do
  if [[ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]]; then
    msg_error "Número máximo de tentativas ($MAX_ATTEMPTS) atingido ao baixar a imagem."
    rm -rf "$TEMP_DIR"
    exit 1
  fi

  if [[ ! -f checksums.sha256 ]]; then
    wget -q -O checksums.sha256 \
      "${MIRROR_URL}/${OPNSENSE_VER}/OPNsense-${OPNSENSE_VER}-checksums-amd64.sha256" || true
  fi

  if [[ -f "${IMG_NAME}.bz2" ]]; then
    if [[ -s "${IMG_NAME}.bz2" ]] && file "${IMG_NAME}.bz2" | grep -q "bzip2 compressed data"; then
      EXPECTED_HASH=$(grep -F "${IMG_NAME}.bz2" checksums.sha256 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
      LOCAL_HASH=$(sha256sum "${IMG_NAME}.bz2" 2>/dev/null | awk '{print $1}' | tr -d ' \r\n')
      if [[ -n "$EXPECTED_HASH" && "$EXPECTED_HASH" == "$LOCAL_HASH" ]]; then
        msg_ok "Imagem local verificada (SHA256 $LOCAL_HASH)"
        break
      else
        msg_warn "Checksum divergente/incompleto (esperado ${EXPECTED_HASH:-?}, obtido ${LOCAL_HASH:-?}) -- rebaixando"
      fi
    else
      msg_warn "Arquivo local corrompido/vazio -- rebaixando"
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi
  fi

  wget -c -q --show-progress -O "${IMG_NAME}.bz2" "${MIRROR_URL}/${OPNSENSE_VER}/${IMG_NAME}.bz2" || true
  ATTEMPT=$((ATTEMPT + 1))
done

msg_info "Descomprimindo a imagem"
bunzip2 -f "${IMG_NAME}.bz2"
msg_ok "Imagem pronta: $TEMP_DIR/$IMG_NAME"

# ── 2) Criação da VM ──────────────────────────────────────────────
msg_info "Criando VM $VMID ($VM_NAME)"
qm create "$VMID" \
  --name "$VM_NAME" \
  --ostype l26 \
  --machine q35 \
  --cores "$CPU_CORES" \
  --cpu host \
  --memory "$RAM_MB" \
  --net0 "virtio,bridge=${BRIDGE_WAN}" \
  --net1 "virtio,bridge=${BRIDGE_LAN}" \
  --serial0 socket \
  --vga serial0 \
  --onboot 1
msg_ok "VM $VMID criada (net0=$BRIDGE_WAN/WAN, net1=$BRIDGE_LAN/LAN-trunk)"

# ── 3) Importação e expansão do disco ────────────────────────────
msg_info "Importando e expandindo o disco"
qm importdisk "$VMID" "$IMG_NAME" "$STORAGE"
qm set "$VMID" --virtio0 "${STORAGE}:vm-${VMID}-disk-0"
qm resize "$VMID" virtio0 "$DISK_EXPAND"
qm set "$VMID" --boot order=virtio0
cd /tmp && rm -rf "$TEMP_DIR"
msg_ok "Disco importado e expandido para $DISK_EXPAND"

# ── 4) Boot inicial ────────────────────────────────────────────────
msg_info "Ligando a VM para automação do primeiro boot"
qm start "$VMID"
msg_ok "VM iniciada -- aguardando ~40s o boot do FreeBSD"
sleep 40

# ── 5) Automação via expect: wizard inicial + gpart/growfs ───────
msg_info "Executando automação do console serial (wizard + expansão do FS)"
expect <<EOF
set timeout 60
spawn qm terminal ${VMID}
send "\r"

expect {
  -re "Do you want to configure LAGGs now.*" { send "n\r"; exp_continue }
  -re "Do you want to configure VLANs now.*" { send "n\r"; exp_continue }
  -re "Enter the WAN interface name.*" { send "vtnet0\r"; exp_continue }
  -re "Enter the LAN interface name.*" { send "vtnet1\r"; exp_continue }
  -re "Enter the Optional interface.*" { send "\r"; exp_continue }
  -re "Do you want to proceed.*" { send "y\r"; exp_continue }
  "login:" { send "root\r"; exp_continue }
  "Password:" { send "opnsense\r"; exp_continue }
  "Enter an option:" { send "8\r" }
  timeout {
    send_user "\n[ERRO] Timeout aguardando resposta do OPNsense.\n"
    exit 1
  }
}

expect "# "
send "gpart recover vtbd0\r"
expect "# "
send "gpart resize -i 3 vtbd0\r"
expect "# "
send "growfs -y /dev/vtbd0p3\r"
expect "# "
send "exit\r"
expect "Enter an option:"
send "\x0f"
expect eof
EOF
msg_ok "Wizard inicial concluído e filesystem expandido (vtnet0=WAN, vtnet1=LAN)"

# ── 6) Restauração de config.xml (opcional) ──────────────────────
# Fluxo unificado: seja qual for a origem (URL ou arquivo local), o
# config.xml sempre passa primeiro por uma cópia local no Proxmox, onde
# aplicamos o ajuste de MSS clamping (1320) em toda interface com MTU 1360
# declarado -- o mesmo padrão de regra scrub-por-interface confirmado no
# backup de referência do pve-odonto. Só depois ele é servido via HTTP
# efêmero na bridge de SNAT (gateway 172.31.0.1) para a VM buscar com
# `fetch` de dentro do próprio OPNsense. Isso evita montar UFS a partir do
# Linux (o driver de escrita não é confiável) e evita depender de acesso
# direto da VM à internet.
CONFIG_URL=""
CONFIG_LOCAL="/tmp/opnsense-${VMID}-config.xml"
if whiptail --yesno "Restaurar config.xml de um backup existente?" 0 0; then
  SRC=$(whiptail --menu "Origem do config.xml:" 0 60 2 \
    "url"   "Baixar de URL (ex: coluna URL_BKPRepo do hosts.csv)" \
    "local" "Arquivo já presente no Proxmox" \
    3>&2 2>&1 1>&3) || true

  case "$SRC" in
    url)
      URL=$(whiptail --inputbox "URL do config.xml, da pasta/tree no GitHub, ou do repositório:" 0 70 "${UFTM_BKP_URL:-}" 3>&2 2>&1 1>&3) || true
      if [[ -n "${URL:-}" ]]; then
        if [[ "$URL" == *github.com/* || "$URL" == *api.github.com/repos/* ]]; then
          # ── Repositório GitHub (privado) ──────────────────────────
          # Suporta: link "tree" para pasta, link "blob" para arquivo
          # específico, link raiz do repo (assume branch main), ou link
          # direto da Contents API. Autentica com Personal Access Token
          # (login/senha não funciona mais na API do GitHub) -- o token é só
          # perguntado aqui, nunca gravado em disco/CSV, igual à chave WireGuard.
          require_cmd curl jq
          GH_TOKEN=$(whiptail --passwordbox "Personal Access Token do GitHub (escopo 'repo', leitura basta):" 0 70 3>&2 2>&1 1>&3) || true
          if [[ -z "${GH_TOKEN:-}" ]]; then
            msg_error "Token não informado -- repositório privado não pode ser acessado."
            CONFIG_LOCAL=""
          else
            read -r GH_MODE GH_OWNER GH_REPO GH_BRANCH GH_PATH <<<"$(python3 - "$URL" <<'PYEOF'
import re, sys
url = sys.argv[1]
m = re.match(r'https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/?(.*)$', url)
if m:
    o, r, b, p = m.groups()
    print("tree", o, r.removesuffix(".git"), b, p or "-"); sys.exit()
m = re.match(r'https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$', url)
if m:
    o, r, b, p = m.groups()
    print("blob", o, r.removesuffix(".git"), b, p); sys.exit()
m = re.match(r'https?://api\.github\.com/repos/([^/]+)/([^/]+)/contents/?([^?]*)\??(?:ref=(.+))?$', url)
if m:
    o, r, p, b = m.groups()
    print("tree", o, r, b or "main", p or "-"); sys.exit()
m = re.match(r'https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$', url)
if m:
    o, r = m.groups()
    print("tree", o, r, "main", "-"); sys.exit()
print("unknown", "", "", "", "")
PYEOF
)"
            [[ "$GH_PATH" == "-" ]] && GH_PATH=""

            if [[ "$GH_MODE" == "unknown" ]]; then
              msg_error "Não reconheci essa URL do GitHub. Use um link 'tree' (pasta), 'blob' (arquivo) ou a raiz do repositório."
              CONFIG_LOCAL=""
            else
              gh_api_download() {
                # gh_api_download <path-na-api> <arquivo-de-saída> [accept-header]
                # Grava a resposta direto em arquivo (binary-safe) e devolve
                # o HTTP status via stdout.
                local api_path="$1" outfile="$2" accept="${3:-application/vnd.github+json}"
                curl -sS -o "$outfile" -w '%{http_code}' \
                  -H "Authorization: token ${GH_TOKEN}" \
                  -H "Accept: ${accept}" \
                  -H "X-GitHub-Api-Version: 2022-11-28" \
                  "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/contents/${api_path}?ref=${GH_BRANCH}"
              }

              if [[ "$GH_MODE" == "blob" ]]; then
                if [[ "${GH_PATH,,}" != *.xml ]]; then
                  msg_error "O arquivo apontado não é .xml: $GH_PATH"
                  CONFIG_LOCAL=""
                else
                  msg_info "Baixando $GH_PATH de ${GH_OWNER}/${GH_REPO}@${GH_BRANCH}"
                  HTTP_CODE=$(gh_api_download "$GH_PATH" "$CONFIG_LOCAL" "application/vnd.github.v3.raw")
                  if [[ "$HTTP_CODE" == "200" ]]; then
                    msg_ok "Arquivo baixado e renomeado para config.xml"
                  else
                    msg_error "GitHub retornou HTTP $HTTP_CODE (token inválido/sem acesso, ou caminho/branch errado)."
                    CONFIG_LOCAL=""
                  fi
                fi
              else
                msg_info "Listando .xml em ${GH_OWNER}/${GH_REPO}@${GH_BRANCH}/${GH_PATH:-/}"
                LISTING_JSON="/tmp/uftm-gh-listing-${VMID}.json"
                HTTP_CODE=$(gh_api_download "$GH_PATH" "$LISTING_JSON")
                if [[ "$HTTP_CODE" != "200" ]]; then
                  msg_error "GitHub retornou HTTP $HTTP_CODE ao listar (token inválido/sem acesso, ou caminho/branch errado)."
                  CONFIG_LOCAL=""
                else
                  mapfile -t XML_NAMES < <(jq -r '.[] | select(.type=="file") | select(.name | test("\\.xml$"; "i")) | .name' "$LISTING_JSON" | sort -r)
                  rm -f "$LISTING_JSON"
                  if [[ "${#XML_NAMES[@]}" -eq 0 ]]; then
                    msg_error "Nenhum .xml encontrado em ${GH_PATH:-/} nesse branch/repositório."
                    CONFIG_LOCAL=""
                  else
                    MENU_ITEMS=(); i=0
                    for n in "${XML_NAMES[@]}"; do MENU_ITEMS+=("$i" "$n"); i=$((i + 1)); done
                    CHOICE_IDX=$(whiptail --menu "Selecione o backup a restaurar (${GH_OWNER}/${GH_REPO}@${GH_BRANCH}):" 0 78 12 "${MENU_ITEMS[@]}" 3>&2 2>&1 1>&3) || true
                    if [[ -n "${CHOICE_IDX:-}" ]]; then
                      SELECTED_NAME="${XML_NAMES[$CHOICE_IDX]}"
                      SELECTED_PATH="${GH_PATH:+${GH_PATH}/}${SELECTED_NAME}"
                      msg_info "Baixando $SELECTED_NAME (será salvo como config.xml)"
                      HTTP_CODE=$(gh_api_download "$SELECTED_PATH" "$CONFIG_LOCAL" "application/vnd.github.v3.raw")
                      if [[ "$HTTP_CODE" == "200" ]]; then
                        msg_ok "Arquivo baixado e renomeado para config.xml"
                      else
                        msg_error "Falha ao baixar $SELECTED_NAME (HTTP $HTTP_CODE)"
                        CONFIG_LOCAL=""
                      fi
                    else
                      CONFIG_LOCAL=""
                    fi
                  fi
                fi
              fi
            fi
          fi
          unset GH_TOKEN
        elif [[ "${URL,,}" == *.xml ]]; then
          # Link direto para o arquivo (repositório público, não-GitHub)
          msg_info "Baixando config.xml"
          wget -q -O "$CONFIG_LOCAL" "$URL" && msg_ok "config.xml baixado" || { msg_error "Falha no download"; CONFIG_LOCAL=""; }
        else
          # Fallback: pasta com listagem de diretório padrão (Apache/nginx
          # autoindex), sem autenticação -- útil se o repositório não for
          # o GitHub. Se o repositório usar outro formato (NAS, WebDAV
          # custom etc.), a listagem pode falhar; nesse caso informe o link
          # direto do arquivo.
          DIR_URL="${URL%/}/"
          msg_info "Listando arquivos .xml em $DIR_URL"
          LISTING_HTML="/tmp/uftm-opnsense-listing-${VMID}.html"
          if wget -q -O "$LISTING_HTML" "$DIR_URL"; then
            mapfile -t XML_LINKS < <(python3 - "$LISTING_HTML" "$DIR_URL" <<'PYEOF'
import sys, re
from urllib.parse import urljoin

html_path, base_url = sys.argv[1], sys.argv[2]
html = open(html_path, encoding="utf-8", errors="replace").read()
hrefs = re.findall(r'href\s*=\s*"([^"]+\.xml)"', html, re.IGNORECASE)
seen = set()
for h in hrefs:
    full = urljoin(base_url, h)
    if full not in seen:
        seen.add(full)
        print(full)
PYEOF
            )
            rm -f "$LISTING_HTML"

            if [[ "${#XML_LINKS[@]}" -eq 0 ]]; then
              msg_error "Nenhum .xml encontrado na listagem de $DIR_URL (repositório pode não expor listagem de diretório -- use o link direto do arquivo)."
              CONFIG_LOCAL=""
            else
              mapfile -t XML_LINKS < <(printf '%s\n' "${XML_LINKS[@]}" | sort -r)
              MENU_ITEMS=()
              i=0
              for link in "${XML_LINKS[@]}"; do
                MENU_ITEMS+=("$i" "$(basename "$link")")
                i=$((i + 1))
              done
              CHOICE_IDX=$(whiptail --menu "Selecione o backup a restaurar ($DIR_URL):" 0 78 12 "${MENU_ITEMS[@]}" 3>&2 2>&1 1>&3) || { CONFIG_LOCAL=""; }
              if [[ -n "${CHOICE_IDX:-}" ]]; then
                SELECTED_URL="${XML_LINKS[$CHOICE_IDX]}"
                msg_info "Baixando $(basename "$SELECTED_URL") (será salvo como config.xml)"
                wget -q -O "$CONFIG_LOCAL" "$SELECTED_URL" && msg_ok "Arquivo baixado e renomeado para config.xml" \
                  || { msg_error "Falha no download de $SELECTED_URL"; CONFIG_LOCAL=""; }
              fi
            fi
          else
            msg_error "Não consegui acessar $DIR_URL"
            CONFIG_LOCAL=""
          fi
        fi
      else
        CONFIG_LOCAL=""
      fi
      ;;
    local)
      LOCAL_PATH=$(whiptail --inputbox "Caminho completo do config.xml OU da pasta de backups no Proxmox:" 0 70 3>&2 2>&1 1>&3) || true
      if [[ -n "${LOCAL_PATH:-}" && -d "$LOCAL_PATH" ]]; then
        mapfile -t XML_FILES < <(find "$LOCAL_PATH" -maxdepth 1 -type f -iname '*.xml' | sort -r)
        if [[ "${#XML_FILES[@]}" -eq 0 ]]; then
          msg_error "Nenhum .xml encontrado em $LOCAL_PATH"
        else
          MENU_ITEMS=(); i=0
          for f in "${XML_FILES[@]}"; do MENU_ITEMS+=("$i" "$(basename "$f")"); i=$((i + 1)); done
          CHOICE_IDX=$(whiptail --menu "Selecione o backup a restaurar ($LOCAL_PATH):" 0 78 12 "${MENU_ITEMS[@]}" 3>&2 2>&1 1>&3) || true
          if [[ -n "${CHOICE_IDX:-}" ]]; then
            cp "${XML_FILES[$CHOICE_IDX]}" "$CONFIG_LOCAL"
            msg_ok "$(basename "${XML_FILES[$CHOICE_IDX]}") copiado e renomeado para config.xml"
          fi
        fi
      elif [[ -n "${LOCAL_PATH:-}" && -f "$LOCAL_PATH" ]]; then
        cp "$LOCAL_PATH" "$CONFIG_LOCAL"
      else
        msg_error "Arquivo não encontrado: ${LOCAL_PATH:-<vazio>}"
        CONFIG_LOCAL=""
      fi
      ;;
    *) CONFIG_LOCAL="" ;;
  esac
fi

if [[ -n "$CONFIG_LOCAL" && -f "$CONFIG_LOCAL" ]]; then
  msg_info "Garantindo MSS clamping (1320) nas interfaces com MTU 1360"
  python3 - "$CONFIG_LOCAL" <<'PYEOF'
import sys, xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()

ifaces = root.find("interfaces")
if ifaces is None:
    sys.exit(0)

mtu1360 = [child.tag for child in ifaces
           if (child.find("mtu") is not None and (child.find("mtu").text or "").strip() == "1360")]

filt = root.find("filter")
if filt is None:
    filt = ET.SubElement(root, "filter")
scrub = filt.find("scrub")
if scrub is None:
    scrub = ET.SubElement(filt, "scrub")

existing = {r.find("interface").text for r in scrub.findall("rule") if r.find("interface") is not None}

changed = False
for ifc in mtu1360:
    if ifc in existing:
        continue
    rule = ET.SubElement(scrub, "rule")
    ET.SubElement(rule, "interface").text = ifc
    ET.SubElement(rule, "proto").text = "any"
    ET.SubElement(rule, "src").text = "any"
    ET.SubElement(rule, "srcmask").text = "24"
    ET.SubElement(rule, "dst").text = "any"
    ET.SubElement(rule, "dstmask").text = "24"
    ET.SubElement(rule, "max-mss").text = "1320"
    ET.SubElement(rule, "descr").text = f"MSS Clamping - {ifc} (auto uftm-proxmox-casas)"
    ET.SubElement(rule, "direction").text = "in"
    changed = True
    print(f"  + regra de MSS clamping adicionada para {ifc}")

if changed:
    tree.write(path, xml_declaration=True, encoding="UTF-8")
else:
    print("  (nada a fazer -- regras já presentes ou nenhuma interface com MTU 1360)")
PYEOF
  msg_ok "config.xml verificado/ajustado"

  SERVE_DIR=$(mktemp -d)
  cp "$CONFIG_LOCAL" "$SERVE_DIR/config.xml"
  SERVE_PORT=8879
  ( cd "$SERVE_DIR" && python3 -m http.server "$SERVE_PORT" --bind 172.31.0.1 &>/tmp/uftm-opnsense-httpserve.log & echo $! >/tmp/uftm-opnsense-httpserve.pid )
  sleep 1
  CONFIG_URL="http://172.31.0.1:${SERVE_PORT}/config.xml"
  msg_ok "Servindo config.xml (já ajustado) temporariamente em $CONFIG_URL"
fi

if [[ -n "$CONFIG_URL" ]]; then
  msg_info "Restaurando config.xml via console serial (fetch + reboot)"
  expect <<EOF
set timeout 60
spawn qm terminal ${VMID}
send "\r"
expect {
  "login:" { send "root\r"; exp_continue }
  "Password:" { send "opnsense\r"; exp_continue }
  "Enter an option:" { send "8\r" }
  timeout { send_user "\n[ERRO] Timeout no login pós-wizard.\n"; exit 1 }
}
expect "# "
send "fetch -o /conf/config.xml '${CONFIG_URL}'\r"
expect "# "
send "cp /conf/config.xml /conf/backup/config-\$(date +%Y%m%d%H%M%S).xml 2>/dev/null; echo done\r"
expect "done"
send "/etc/rc.reboot\r"
expect eof
EOF
  # Encerra o servidor HTTP temporário, se foi usado
  if [[ -f /tmp/uftm-opnsense-httpserve.pid ]]; then
    kill "$(cat /tmp/uftm-opnsense-httpserve.pid)" 2>/dev/null || true
    rm -f /tmp/uftm-opnsense-httpserve.pid
  fi
  msg_ok "config.xml restaurado e VM reiniciada para aplicar"
  msg_warn "Confira pelo console (qm terminal $VMID) se o boot voltou normalmente com as interfaces/VLANs do config.xml restaurado."
else
  msg_ok "Instalação limpa (sem restauração de config.xml) -- WAN/LAN ficam com DHCP padrão do wizard, ajuste depois pela GUI."
fi

msg_ok "opnsense-vm.sh concluído (VM $VMID / $VM_NAME)"
