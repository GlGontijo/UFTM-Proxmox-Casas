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
BRIDGE_WAN="vnetsnat"
BRIDGE_LAN="vmbr1"
CPU_CORES="2"
RAM_MB="2048"
DISK_EXPAND="+200G"

OPNSENSE_VER="26.7"
MIRROR_URL="https://pkg.opnsense.org/releases/"
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
# 1. VERIFICAÇÃO LOCAL E DOWNLOAD SOB DEMANDA (WITH RESUME -c)
# ------------------------------------------------------------------------------
TEMP_DIR="/tmp/opnsense_deploy_${VM_ID}"
mkdir -p "${TEMP_DIR}"
cd "${TEMP_DIR}"

MAX_ATTEMPTS=5
ATTEMPT=1

echo "[1/6] Iniciando verificação e download da imagem OPNsense..."
echo "-> Tentativa ${ATTEMPT} de ${MAX_ATTEMPTS}..."

while true; do
  if [ "${ATTEMPT}" -gt "${MAX_ATTEMPTS}" ]; then
    echo "[ERRO CRÍTICO] Número máximo de tentativas (${MAX_ATTEMPTS}) atingido. Abortando." >&2
    rm -rf "${TEMP_DIR}"
    exit 1
  elif [ "${ATTEMPT}" -gt 1 ]; then
    echo "-> Tentativa ${ATTEMPT} de ${MAX_ATTEMPTS}..."
  fi

  # Garante que o arquivo de checksums oficial exista para consulta
  if [ ! -f "checksums.sha256" ]; then
    echo "   Baixando arquivo de checksums oficial..."
    wget -q -O "checksums.sha256" "${MIRROR_URL}/${OPNSENSE_VER}/OPNsense-${OPNSENSE_VER}-checksums-amd64.sha256" || true
  fi

  # Se o arquivo existe em disco, valida integridade física e hash ANTES de baixar
  if [ -f "${IMG_NAME}.bz2" ]; then
    # Checa se é um bzip2 válido
    if [ -s "${IMG_NAME}.bz2" ] && file "${IMG_NAME}.bz2" | grep -q "bzip2 compressed data"; then
      EXPECTED_HASH=$(grep -F "${IMG_NAME}.bz2" checksums.sha256 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
      LOCAL_HASH=$(sha256sum "${IMG_NAME}.bz2" 2>/dev/null | awk '{print $1}' | tr -d ' \r\n')

      if [ -n "${EXPECTED_HASH}" ] && [ "${EXPECTED_HASH}" = "${LOCAL_HASH}" ]; then
        echo "   [SUCESSO] Arquivo local verificado com sucesso!"
        echo "   Hash SHA256: ${LOCAL_HASH}"
        break
      else
        echo "   [AVISO] Arquivo local existe mas o checksum divergiu ou está incompleto."
        echo "     Esperado: ${EXPECTED_HASH:-'Não encontrado'}"
        echo "     Obtido:   ${LOCAL_HASH:-'Erro ao calcular'}"
      fi
    else
      echo "   [AVISO] Arquivo local encontrado, porém está vazio ou corrompido."
      ATTEMPT=$((ATTEMPT + 1))
      continue
      sleep 2
    fi
  else
    echo "   Arquivo ${IMG_NAME}.bz2 não encontrado localmente."
  fi

  # Executa/Retoma (-c) o download
  echo "   Baixando/retomando download de ${IMG_NAME}.bz2..."
  wget -c -q --show-progress -O "${IMG_NAME}.bz2" "${MIRROR_URL}/${OPNSENSE_VER}/${IMG_NAME}.bz2" || true

done

# Descompressão após validação confirmada pelo 'break'
echo "[2/6] Descomprimindo a imagem..."
bunzip2 -f "${IMG_NAME}.bz2"

# ------------------------------------------------------------------------------
# 2. CRIAÇÃO DA VM COM SUPORTE A CONSOLE SERIAL
# ------------------------------------------------------------------------------
echo "[3/6] Criando estrutura da VM (${VM_NAME})..."
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
echo "[4/6] Importando e vinculando o disco..."
qm importdisk "${VM_ID}" "${IMG_NAME}" "${STORAGE}"
qm set "${VM_ID}" --virtio0 "${STORAGE}:vm-${VM_ID}-disk-0"
qm resize "${VM_ID}" virtio0 "${DISK_EXPAND}"
qm set "${VM_ID}" --boot order=virtio0

# Limpeza do arquivo de imagem baixado
cd /tmp && rm -rf "${TEMP_DIR}"

# ------------------------------------------------------------------------------
# 4. INICIALIZAÇÃO DA VM
# ------------------------------------------------------------------------------
echo "[5/6] Ligando a VM para automação do boot..."
qm start "${VM_ID}"

echo "   Aguardando a inicialização do FreeBSD no console (pode levar ~40s)..."
sleep 40

# ------------------------------------------------------------------------------
# 5. AUTOMAÇÃO VIA EXPECT (HANDSHAKE NETWORK ASSIGNMENT + GPART)
# ------------------------------------------------------------------------------
echo "[6/6] Executando rotina de ajuste via Console Serial..."

expect << EOF
set timeout 60

spawn qm terminal ${VM_ID}

send "\r"

# Loop dinâmico para lidar com assistentes de boot inicial e login
expect {
    # Caso caia na pergunta de LAGGs
    -re "Do you want to configure LAGGs now.*" {
        send "n\r"
        exp_continue
    }
    # Caso caia na pergunta de VLANs
    -re "Do you want to configure VLANs now.*" {
        send "n\r"
        exp_continue
    }
    # Caso peça a interface WAN/LAN diretamente no wizard
    -re "Enter the WAN interface name.*" {
        send "vnet0\r"
        exp_continue
    }
    -re "Enter the LAN interface name.*" {
        send "vnet1\r"
        exp_continue
    }
    # Caso pergunte se deseja prosseguir
    -re "Do you want to proceed.*" {
        send "y\r"
        exp_continue
    }
    # Login de usuário
    "login:" {
        send "root\r"
        exp_continue
    }
    "Password:" {
        send "opnsense\r"
        exp_continue
    }
    # Quando alcançar o menu do OPNsense
    "Enter an option:" {
        send "8\r"
    }
    timeout {
        send_user "\n[ERRO] Timeout aguardando a resposta do OPNsense.\n"
        exit 1
    }
}

# Execução do gpart dentro do Shell FreeBSD (Option 8)
expect "# "
send "gpart recover vtbd0\r"

expect "# "
send "gpart resize -i 3 vtbd0\r"

expect "# "
send "growfs -y /dev/vtbd0p3\r"

# Sai do Shell e volta para o menu
expect "# "
send "exit\r"

expect "Enter an option:"
# Desconecta do qm terminal (Ctrl+O)
send "\x0f"
expect eof
EOF

echo "======================================================================"
echo " Processo concluído com sucesso!"
echo " A VM '${VM_NAME}' (ID ${VM_ID}) foi criada e expandida."
echo "======================================================================"
