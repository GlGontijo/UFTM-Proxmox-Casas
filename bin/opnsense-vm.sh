#!/usr/bin/env bash
#
# bin/opnsense-vm.sh
# ETAPA 7 do fluxo. Cria a VM OPNsense (imagem "nano") e automatiza o
# primeiro boot via console serial. NÃO baixa nada (a imagem e o
# config.xml, se houver, já foram deixados em cache por download-deps.sh
# na etapa 3 -- por essa altura a internet do laboratório já pode ter
# caído de propósito).
#
# BUG CORRIGIDO em relação à versão anterior: as respostas do wizard para
# "Enter the WAN/LAN interface name" estavam como vnet0/vnet1 -- interfaces
# virtio no FreeBSD aparecem como vtnet0/vtnet1.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_cmd qm expect
state_load

: "${UFTM_LAN_BRIDGE:?Rode bin/wizard.sh + network-install.sh antes}"
: "${UFTM_OPN_IMG_PATH:?Imagem OPNsense não está em cache -- rode bin/download-deps.sh (etapa 3) antes}"

STORAGE="${UFTM_OPN_STORAGE:-local-lvm}"
BRIDGE_WAN="vnetsnat"
BRIDGE_LAN="$UFTM_LAN_BRIDGE"
CPU_CORES="${UFTM_OPN_CPU:-2}"
RAM_MB="${UFTM_OPN_RAM:-4096}"
DISK_SIZE="${UFTM_OPN_DISK:-200G}"
OPNSENSE_VER="${UFTM_OPN_VER:-26.7}"
IMG_PATH="$UFTM_OPN_IMG_PATH"

# ── Nome da VM a partir do hostname do Proxmox ──────────────────
PROXMOX_HOST="${UFTM_HOSTNAME:-$(hostname -s)}"
SUFFIX="${PROXMOX_HOST#pve-}"; SUFFIX="${SUFFIX#PVE-}"
VM_NAME=$(echo "opnsense-${SUFFIX}" | tr '[:upper:]' '[:lower:]')

# ── VMID: 100 por padrão; se já existir, excluir/recriar ou usar o próximo livre ──
# (esta pergunta fica de propósito FORA do wizard -- é uma confirmação
# destrutiva em tempo de execução, não um dado de configuração do site.)
VMID=100
while qm status "$VMID" &>/dev/null; do
  if whiptail --yesno "Já existe uma VM com ID $VMID.\nExcluir e recriar?" 0 0; then
    msg_info "Removendo VM $VMID existente"
    qm stop "$VMID" --skiplock 1 &>/dev/null || true
    qm destroy "$VMID" --purge 1 &>/dev/null
    msg_ok "VM $VMID removida"
    break
  else
    if whiptail --yesno "Deseja instalar uma nova VM com ID $((VMID + 1))?\n \
        \n'SIM': OPNsense será instalado.\n'NÃO': Criação da VM será abortada." 0 0 ; then
      VMID=$((VMID + 1))
    else
      masg_info "Instalação da VM cancelada pelo usuáŕio."
      VMID=0
    fi
  fi
done

if [[ "$VMID" > 0 ]]; then
  msg_ok "VM: $VM_NAME (ID $VMID) -- net0=$BRIDGE_WAN/WAN, net1=$BRIDGE_LAN/LAN-trunk, ${CPU_CORES}vCPU/${RAM_MB}MB/${DISK_SIZE}, OPNsense $OPNSENSE_VER"

  # ── 1) Criação da VM ──────────────────────────────────────────────
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
  msg_ok "VM $VMID criada"

  # ── 2) Importação e expansão do disco (imagem já em cache) ───────
  msg_info "Importando e expandindo o disco a partir de $IMG_PATH"
  qm importdisk "$VMID" "$IMG_PATH" "$STORAGE"
  qm set "$VMID" --virtio0 "${STORAGE}:vm-${VMID}-disk-0"
  qm resize "$VMID" virtio0 "$DISK_SIZE"
  qm set "$VMID" --boot order=virtio0
  msg_ok "Disco importado e expandido para $DISK_SIZE"

  # ── 3) Boot inicial ────────────────────────────────────────────────
  msg_info "Ligando a VM para automação do primeiro boot"
  qm start "$VMID"
  msg_ok "VM iniciada -- aguardando ~40s o boot do FreeBSD"
  sleep 40

  # ── 4) Automação via expect: wizard inicial + gpart/growfs ───────
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

  # ── 5) Restauração de config.xml (se veio em cache de download-deps.sh) ──
  # O arquivo já foi baixado/escolhido/renomeado para config.xml na etapa 3.
  # Aqui só aplicamos o MSS clamping (1320) nas interfaces com MTU 1360 e
  # entregamos via HTTP efêmero na bridge de SNAT para a VM buscar com
  # `fetch` de dentro do próprio OPNsense (evita montar UFS pelo lado Linux).
  CONFIG_URL=""
  if [[ -n "${UFTM_OPN_CONFIG_XML_PATH:-}" && -f "$UFTM_OPN_CONFIG_XML_PATH" ]]; then
    CONFIG_LOCAL="$UFTM_OPN_CONFIG_XML_PATH"
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
    if [[ -f /tmp/uftm-opnsense-httpserve.pid ]]; then
      kill "$(cat /tmp/uftm-opnsense-httpserve.pid)" 2>/dev/null || true
      rm -f /tmp/uftm-opnsense-httpserve.pid
    fi
    msg_ok "config.xml restaurado e VM reiniciada para aplicar"
    msg_warn "Confira pelo console (qm terminal $VMID) se o boot voltou normalmente."
  else
    msg_ok "Instalação limpa (sem restauração de config.xml) -- WAN/LAN ficam com DHCP padrão do wizard, ajuste depois pela GUI."
  fi

  state_set UFTM_OPN_VMID "$VMID"
  state_mark_step "opnsense-vm"
  msg_ok "opnsense-vm.sh concluído (VM $VMID / $VM_NAME)"
fi
