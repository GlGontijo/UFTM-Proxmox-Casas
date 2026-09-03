#!/usr/bin/env bash
# ==============================================================================
# Script de Criação e Automação de VM OPNsense (Nano) no Proxmox VE
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# VARIÁVEIS CONFIGURÁVEIS
# ------------------------------------------------------------------------------
VM_ID="100"
STORAGE="local-lvm"
BRIDGE_WAN="vmbr0"
BRIDGE_LAN="vmbr1"
CPU_CORES="2"
RAM_MB="2048"
DISK_EXPAND="+8G"

OPNSENSE_VER="24.1"
MIRROR_URL="https://mirror.dns-net.de/opnsense/releases"
IMG_NAME="OPNsense-${OPNSENSE_VER}-nano-amd64.img"

# ------------------------------------------------------------------------------
# DEFINIÇÃO DINÂMICA DO NOME DA VM
# ------------------------------------------------------------------------------
PROXMOX_HOST=$(hostname -s)
SUFFIX="${PROXMOX_HOST#pve-}"
SUFFIX="${SUFFIX#PVE-}"
VM_NAME="opnsense-${SUFFIX}"
VM_NAME=$(echo "${VM_NAME}" | tr '[:upper:]' '[:lower:]')

# ------------------------------------------------------------------------------
# CHECAGENS INICIAIS
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "[ERRO] Este script deve ser executado como root." >&2
  exit 1
fi

if ! command -v expect &>/dev/null; then
  echo "[INFO] Instalando dependência 'expect'..."
  apt-get update -qq && apt-get install -y -qq expect
fi

if qm status "${VM_ID}" &>/dev/null; then
  echo "[ERRO] A VM com ID ${VM_ID} já existe!" >&2
  exit 1
fi

echo "======================================================================"
echo " Host Proxmox: ${PROXMOX_HOST}"
echo " Nome da VM:   ${VM_NAME}"
echo " VM ID:        ${VM_ID}"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. DOWNLOAD E PREPARAÇÃO DA IMAGEM
# ------------------------------------------------------------------------------
TEMP_DIR="/tmp/opnsense_deploy_${VM_ID}"
mkdir -p "${TEMP_DIR}"
cd "${TEMP_DIR}"

echo "[1/6] Baixando e descomprimindo imagem..."
wget -q --show-progress -O "${IMG_NAME}.bz2" "${MIRROR_URL}/${OPNSENSE_VER}/${IMG_NAME}.bz2"
bunzip2 -f "${IMG_NAME}.bz2"

# ------------------------------------------------------------------------------
# 2. CRIAÇÃO DA VM COM SUPORTE A CONSOLE SERIAL
# ------------------------------------------------------------------------------
echo "[2/6] Criando estrutura da VM (${VM_NAME})..."
qm create "${VM_ID}" \
  --name "${VM_NAME}" \
  --ostype l26 \
  --machine q35 \
  --cores "${CPU_CORES}" \
  --cpu host \
  --memory "${RAM_MB}" \
  --net0 virtio,bridge="${BRIDGE_WAN}" \
  --net1 virtio,bridge="${BRIDGE_LAN}" \
  --serial0 socket \
  --vga serial0 \
  --onboot 1

# ------------------------------------------------------------------------------
# 3. IMPORTAÇÃO E EXPANSÃO DO DISCO
# ------------------------------------------------------------------------------
echo "[3/6] Importando e vinculando o disco..."
qm importdisk "${VM_ID}" "${IMG_NAME}" "${STORAGE}"
qm set "${VM_ID}" --virtio0 "${STORAGE}:vm-${VM_ID}-disk-0"
qm resize "${VM_ID}" virtio0 "${DISK_EXPAND}"
qm set "${VM_ID}" --boot order=virtio0

# Limpeza do arquivo de imagem baixado
cd /tmp && rm -rf "${TEMP_DIR}"

# ------------------------------------------------------------------------------
# 4. INICIALIZAÇÃO DA VM
# ------------------------------------------------------------------------------
echo "[4/6] Ligando a VM para automação do boot..."
qm start "${VM_ID}"

echo "[5/6] Aguardando a inicialização do FreeBSD no console (pode levar ~40s)..."
sleep 40

# ------------------------------------------------------------------------------
# 5. AUTOMAÇÃO VIA EXPECT (GPART EXPANSION)
# ------------------------------------------------------------------------------
echo "[6/6] Executando rotina gpart via Console Serial..."

expect << EOF
set timeout 60

spawn qm terminal ${VM_ID}

send "\r"

expect {
    "login:" {
        send "root\r"
        exp_continue
    }
    "Password:" {
        send "opnsense\r"
        exp_continue
    }
    "Enter an option:" {
        send "8\r"
    }
    timeout {
        puts "\n[ERRO] Timeout aguardando a tela de login do OPNsense."
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

echo "======================================================================"
echo " Processo concluído com sucesso!"
echo " A VM '${VM_NAME}' (ID ${VM_ID}) foi criada e expandida."
echo "======================================================================"
