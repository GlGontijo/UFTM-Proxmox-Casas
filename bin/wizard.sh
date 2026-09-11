#!/usr/bin/env bash
#
# bin/wizard.sh
# ETAPA 2 do fluxo. Reúne TODO o questionário do projeto num único lugar --
# nenhum outro script (network-install, sdn-install, hostname-and-restart,
# opnsense-vm, pve-firewall-config) pergunta nada ao usuário: todos leem o
# arquivo de estado gravado aqui.
#
# Resumível: cada resposta é gravada assim que é dada (via state_set), então
# se o processo for interrompido, rodar ./setup.sh de novo detecta o estado
# parcial e oferece continuar de onde parou.
#
# Ao final: tela de resumo com Continuar / Refazer do zero / Cancelar.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_cmd whiptail

CSV_FILE="${UFTM_CSV_FILE:-$SCRIPT_DIR/data/hosts.csv}"
CSV_EXPECTED_COLS=5

if [[ -f "$UFTM_STATE_FILE" ]]; then
  state_load
fi

# ── Retomar? ──────────────────────────────────────────────────────
if [[ -f "$UFTM_STATE_FILE" ]] && [[ "${UFTM_WIZARD_DONE:-0}" != "1" ]] && [[ -n "${UFTM_HOSTNAME:-}" ]]; then
  if whiptail --yesno "Encontrei uma configuração de wizard incompleta para '$UFTM_HOSTNAME'.\n\nRetomar de onde parou? (Não = começar um wizard novo do zero)" 0 0; then
    msg_ok "Retomando estado anterior"
  else
    rm -f "$UFTM_STATE_FILE"
    state_load 2>/dev/null || true
  fi
elif [[ -f "$UFTM_STATE_FILE" ]] && [[ "${UFTM_WIZARD_DONE:-0}" == "1" ]]; then
  if whiptail --yesno "Já existe uma configuração completa para '$UFTM_HOSTNAME' neste host.\n\nRefazer o wizard do zero? (Não = manter e pular direto pro resumo)" 0 0; then
    rm -f "$UFTM_STATE_FILE"
  fi
else 
  msg_ok "Primeira vez por aqui? Vamos seguir do zero então."
fi

# ═══════════════════════════════════════════════════════════════
# 1) Host: CSV ou manual
# ═══════════════════════════════════════════════════════════════
if [[ -z "${UFTM_HOSTNAME:-}" ]]; then
  if [[ ! -f "$CSV_FILE" ]]; then
    msg_error "Arquivo CSV não encontrado: $CSV_FILE"
    echo "Copie data/hosts.csv.example para data/hosts.csv e preencha," >&2
    exit 1
  fi
  if ! csv_validate_columns "$CSV_FILE" "$CSV_EXPECTED_COLS"; then
    msg_error "hosts.csv com linha(s) malformada(s) (colunas != $CSV_EXPECTED_COLS):"
    csv_validate_columns "$CSV_FILE" "$CSV_EXPECTED_COLS" >&2 || true
    exit 1
  fi

  menu_items=()
  while IFS=';' read -r host _; do
    [[ "$host" == "Host" || -z "$host" ]] && continue
    menu_items+=("$host" "")
  done <"$CSV_FILE"
  menu_items+=("MANUAL" "Configuração avançada (informar manualmente)")

  HOST_CHOICE=$(whiptail --backtitle "UFTM Proxmox Setup" --title "Selecione o Host" \
    --menu "Escolha o host (dados vêm da planilha) ou configure manualmente:" 0 70 12 \
    "${menu_items[@]}" 3>&2 2>&1 1>&3) || exit 1

  if [[ "$HOST_CHOICE" == "MANUAL" ]]; then
    UFTM_HOSTNAME=$(whiptail --inputbox "Hostname base (ex: pve-filial-x):" 0 70 3>&2 2>&1 1>&3) || exit 1
    UFTM_WG_PORT=$(whiptail --inputbox "Porta WireGuard:" 0 70 "51820" 3>&2 2>&1 1>&3) || exit 1
    UFTM_WG_TUNNEL_IP=$(whiptail --inputbox "IP do túnel WireGuard (ex: 10.255.255.X):" 0 70 3>&2 2>&1 1>&3) || exit 1
    UFTM_OPNSENSE=$(whiptail --menu "Instalar VM OPNsense neste site?" 0 60 2 "s" "Sim" "n" "Não" 3>&2 2>&1 1>&3) || exit 1
    UFTM_BKP_URL=""
    [[ "$UFTM_OPNSENSE" == "s" ]] && UFTM_BKP_URL=$(whiptail --inputbox "URL/pasta do backup do config.xml (vazio = instalação limpa):" 0 70 3>&2 2>&1 1>&3 || true)
  else
    ROW=$(csv_get_row "$CSV_FILE" "$HOST_CHOICE") || { msg_error "Host '$HOST_CHOICE' não encontrado no CSV"; exit 1; }
    IFS=';' read -r UFTM_HOSTNAME UFTM_WG_PORT UFTM_WG_TUNNEL_IP UFTM_OPNSENSE UFTM_BKP_URL <<<"$ROW"
  fi

  state_set UFTM_HOSTNAME "$UFTM_HOSTNAME"
  state_set UFTM_WG_PORT "$UFTM_WG_PORT"
  state_set UFTM_WG_TUNNEL_IP "$UFTM_WG_TUNNEL_IP"
  state_set UFTM_OPNSENSE "$UFTM_OPNSENSE"
  state_set UFTM_BKP_URL "$UFTM_BKP_URL"
  msg_ok "Host selecionado: $UFTM_HOSTNAME"

  HUB_HOSTNAME_PREFIX="pve-vpnserver"
  UFTM_IS_HUB="n"
  if [[ "$UFTM_HOSTNAME" == "$HUB_HOSTNAME_PREFIX"* ]]; then
    if whiptail --yesno "Hostname começa com '$HUB_HOSTNAME_PREFIX'. Este é o nó HUB do fabric WireGuard?" 0 0; then
      UFTM_IS_HUB="s"
    fi
  fi
  state_set UFTM_IS_HUB "$UFTM_IS_HUB"
fi

# ═══════════════════════════════════════════════════════════════
# 2) Dados sensíveis (IP WAN + chave WireGuard) -- nunca vão pro CSV
# ═══════════════════════════════════════════════════════════════
if [[ -z "${UFTM_IP_WAN_SET:-}" ]]; then
  UFTM_IP_WAN=$(whiptail --inputbox "IP WAN deste site (deixe vazio se WAN=DHCP/PPPoE):" 0 70 3>&2 2>&1 1>&3) || exit 1
  state_set UFTM_IP_WAN "$UFTM_IP_WAN"
  state_set UFTM_IP_WAN_SET "1"
fi

if [[ -z "${UFTM_WG_PK_SET:-}" ]]; then
  WG_MODE=$(whiptail --menu "Chave privada WireGuard:" 0 60 2 \
    "informar" "Informar chave existente (padrão)" \
    "gerar" "Gerar novo par com wg genkey" \
    3>&2 2>&1 1>&3) || exit 1
  if [[ "$WG_MODE" == "gerar" ]]; then
    require_cmd wg
    UFTM_WG_PK=$(wg genkey)
    whiptail --msgbox "Chave privada gerada. Chave pública correspondente:\n\n$(echo "$UFTM_WG_PK" | wg pubkey)\n\n(a privada fica só no estado local do host, nunca é exibida de novo)" 0 70
  else
    UFTM_WG_PK=$(whiptail --inputbox "Chave privada WireGuard (WG_PK):" 0 70 3>&2 2>&1 1>&3) || exit 1
  fi
  state_set UFTM_WG_PK "$UFTM_WG_PK"
  state_set UFTM_WG_PK_SET "1"
fi

# ═══════════════════════════════════════════════════════════════
# 3) Patrimônio / hostname final (NÃO aplica ainda -- isso é feito só na
#    etapa 5, hostname-and-restart.sh, depois da rede já configurada)
# ═══════════════════════════════════════════════════════════════
if [[ -z "${UFTM_PATRIMONIO:-}" ]]; then
  PATRIMONIO=""
  while [[ -z "$PATRIMONIO" ]]; do
    PATRIMONIO=$(whiptail --inputbox "Número de patrimônio do PC:" 0 60 3>&2 2>&1 1>&3) || exit 1
    if [[ ! "$PATRIMONIO" =~ ^[0-9]+$ ]]; then
      whiptail --msgbox "Deve conter apenas dígitos." 0 0
      PATRIMONIO=""
    fi
  done
  state_set UFTM_PATRIMONIO "$PATRIMONIO"
  state_set UFTM_HOSTNAME_FINAL "${UFTM_HOSTNAME}-${PATRIMONIO}"
fi

# ═══════════════════════════════════════════════════════════════
# 4) Domínio local + IP de gerência (necessário em /etc/hosts pro Proxmox
#    subir corretamente -- aplicado na etapa 5)
# ═══════════════════════════════════════════════════════════════
if [[ -z "${UFTM_DOMAIN:-}" ]]; then
  UFTM_DOMAIN=$(whiptail --inputbox "Domínio local (sufixo do FQDN, sem ponto inicial):" 0 60 "uftm" 3>&2 2>&1 1>&3) || exit 1
  state_set UFTM_DOMAIN "$UFTM_DOMAIN"
fi
if [[ -z "${UFTM_MGMT_IP:-}" ]]; then
  UFTM_MGMT_IP=$(whiptail --inputbox "IP de gerência deste host na VLAN de gestão (ex: 10.10.15.X, sem /máscara):" 0 70 3>&2 2>&1 1>&3) || exit 1
  while ! is_valid_ipv4 "$UFTM_MGMT_IP"; do
    UFTM_MGMT_IP=$(whiptail --inputbox "IP inválido. IP de gerência (ex: 10.10.15.X):" 0 70 3>&2 2>&1 1>&3) || exit 1
  done
  state_set UFTM_MGMT_IP "$UFTM_MGMT_IP"
fi

# ═══════════════════════════════════════════════════════════════
# 5) Rede: WAN (DHCP/Fixo/PPPoE), LAN trunk, console opcional
# ═══════════════════════════════════════════════════════════════
if [[ -z "${UFTM_NET_DONE:-}" ]]; then
  mapfile -t NIC_LIST < <(ip -o link show | awk -F': ' '{print $2}' | \
    grep -Ev '^(lo|vmbr|wg|vnet|fwbr|fwln|tap|veth|pppoe|bond)')
  if [[ "${#NIC_LIST[@]}" -eq 0 ]]; then
    msg_error "Nenhuma interface física detectada."
    exit 1
  fi

  nic_menu() {
    local m=()
    for n in "${NIC_LIST[@]}"; do
      local mac state
      mac=$(cat "/sys/class/net/$n/address" 2>/dev/null || echo "?")
      state=$(cat "/sys/class/net/$n/operstate" 2>/dev/null || echo "?")
      m+=("$n" "$mac / $state")
    done
    whiptail --menu "$1" 0 70 "${#NIC_LIST[@]}" "${m[@]}" 3>&2 2>&1 1>&3
  }

  find_bridge_for_nic() {
    local nic="$1" br
    for br in /sys/class/net/*/brif/"$nic"; do
      [[ -e "$br" ]] || continue
      basename "$(dirname "$(dirname "$br")")"
      return 0
    done
    return 1
  }

  confirm_or_new_bridge() {
    local nic="$1" uso="$2" __outvar="$3" existing br_name
    if existing=$(find_bridge_for_nic "$nic" 2>/dev/null); then
      if whiptail --yesno "A interface '$nic' já está escravizada na bridge '$existing'.\nReutilizar essa bridge para $uso?" 0 0; then
        printf -v "$__outvar" '%s' "$existing"
        return 0
      fi
    fi
    br_name=$(whiptail --inputbox "Nome da bridge para $uso (ex: vmbr0):" 0 60 "vmbr$((RANDOM % 8))" 3>&2 2>&1 1>&3) || exit 1
    printf -v "$__outvar" '%s' "$br_name"
  }

  WAN_NIC=$(nic_menu "Interface física para WAN:") || exit 1
  confirm_or_new_bridge "$WAN_NIC" "WAN" WAN_BRIDGE

  WAN_MODE=$(whiptail --menu "Modo de conexão da WAN:" 0 60 3 \
    "dhcp" "DHCP" "static" "IP Fixo" "pppoe" "PPPoE (provedor UFTM)" 3>&2 2>&1 1>&3) || exit 1

  WAN_IP=""; WAN_GW=""; PPPOE_USER=""; PPPOE_PASS=""; PPPOE_MTU=1492
  case "$WAN_MODE" in
    static)
      WAN_IP=$(whiptail --inputbox "IP/CIDR da WAN (ex: 200.1.2.3/29):" 0 60 3>&2 2>&1 1>&3) || exit 1
      WAN_GW=$(whiptail --inputbox "Gateway da WAN:" 0 60 3>&2 2>&1 1>&3) || exit 1
      ;;
    pppoe)
      PPPOE_USER=$(whiptail --inputbox "Usuário PPPoE:" 0 60 3>&2 2>&1 1>&3) || exit 1
      PPPOE_PASS=$(whiptail --passwordbox "Senha PPPoE:" 0 60 3>&2 2>&1 1>&3) || exit 1
      PPPOE_MTU=$(whiptail --inputbox "MTU do PPPoE (padrão 1492):" 0 60 "1492" 3>&2 2>&1 1>&3) || exit 1
      [[ -z "$PPPOE_USER" || -z "$PPPOE_PASS" ]] && { msg_error "Usuário e senha PPPoE são obrigatórios."; exit 1; }
      ;;
  esac

  LAN_NIC=$(nic_menu "Interface física de trunk para a LAN (VLANs):") || exit 1
  if [[ "$LAN_NIC" == "$WAN_NIC" ]]; then
    msg_error "A interface de LAN não pode ser a mesma da WAN."
    exit 1
  fi
  confirm_or_new_bridge "$LAN_NIC" "LAN (trunk)" LAN_BRIDGE

  CONSOLE_BRIDGE=""; CONSOLE_NIC=""; CONSOLE_CIDR=""
  if whiptail --yesno "Configurar uma interface dedicada de console/gerência (ex: vmcsl, 192.168.100.1/24)?" 0 0; then
    CONSOLE_NIC=$(nic_menu "Interface física para console:") || exit 1
    confirm_or_new_bridge "$CONSOLE_NIC" "Console" CONSOLE_BRIDGE
    CONSOLE_CIDR=$(whiptail --inputbox "IP/CIDR do console:" 0 60 "192.168.100.1/24" 3>&2 2>&1 1>&3) || exit 1
  fi

  state_set UFTM_WAN_NIC "$WAN_NIC"
  state_set UFTM_WAN_BRIDGE "$WAN_BRIDGE"
  state_set UFTM_WAN_MODE "$WAN_MODE"
  state_set UFTM_WAN_IP "$WAN_IP"
  state_set UFTM_WAN_GW "$WAN_GW"
  state_set UFTM_PPPOE_USER "$PPPOE_USER"
  state_set UFTM_PPPOE_PASS "$PPPOE_PASS"
  state_set UFTM_PPPOE_MTU "$PPPOE_MTU"
  state_set UFTM_LAN_NIC "$LAN_NIC"
  state_set UFTM_LAN_BRIDGE "$LAN_BRIDGE"
  state_set UFTM_CONSOLE_NIC "$CONSOLE_NIC"
  state_set UFTM_CONSOLE_BRIDGE "$CONSOLE_BRIDGE"
  state_set UFTM_CONSOLE_CIDR "$CONSOLE_CIDR"
  state_set UFTM_NET_DONE "1"
  msg_ok "Configuração de rede coletada"
fi

# ═══════════════════════════════════════════════════════════════
# 6) VLANs a provisionar no fabric EVPN
# ═══════════════════════════════════════════════════════════════
if [[ -z "${UFTM_SELECTED_VLANS:-}" ]]; then
  DEFAULT_VLANS=(1010 1011 1012 1022 1054 1630)
  VLAN_CHOICES=()
  for v in "${DEFAULT_VLANS[@]}"; do VLAN_CHOICES+=("$v" "VLAN $v" ON); done
  SELECTED_VLANS=$(whiptail --checklist "Selecione as VLANs a provisionar como vnet:" 0 70 8 \
    "${VLAN_CHOICES[@]}" 3>&2 2>&1 1>&3) || exit 1
  SELECTED_VLANS=$(echo "$SELECTED_VLANS" | tr -d '"')
  if whiptail --yesno "Adicionar alguma VLAN extra além da lista padrão?" 0 0; then
    EXTRA=$(whiptail --inputbox "VLANs extras separadas por espaço:" 0 60 3>&2 2>&1 1>&3) || true
    SELECTED_VLANS="$SELECTED_VLANS $EXTRA"
  fi
  state_set UFTM_SELECTED_VLANS "$SELECTED_VLANS"
  msg_ok "VLANs selecionadas: $SELECTED_VLANS"
fi

# ═══════════════════════════════════════════════════════════════
# 7) OPNsense: parâmetros da VM + origem do backup (SEM baixar nada
#    ainda -- isso é feito na etapa 3, download-deps.sh)
# ═══════════════════════════════════════════════════════════════
if [[ "$UFTM_OPNSENSE" =~ ^[SsYy] ]] && [[ -z "${UFTM_OPNSENSE_PARAMS_DONE:-}" ]]; then
  OPN_STORAGE=$(whiptail --inputbox "Storage para o disco da VM OPNsense:" 0 60 "local-lvm" 3>&2 2>&1 1>&3) || exit 1
  OPN_CPU=$(whiptail --inputbox "vCPUs:" 0 50 "2" 3>&2 2>&1 1>&3) || exit 1
  OPN_RAM=$(whiptail --inputbox "RAM (MB):" 0 50 "4096" 3>&2 2>&1 1>&3) || exit 1
  OPN_DISK=$(whiptail --inputbox "Tamanho do disco (ex: 200G):" 0 50 "200G" 3>&2 2>&1 1>&3) || exit 1
  OPN_VER=$(whiptail --inputbox "Versão do OPNsense:" 0 50 "26.7" 3>&2 2>&1 1>&3) || exit 1

  OPN_BKP_MODE="none"
  if whiptail --yesno "Restaurar config.xml de um backup existente?" 0 0; then
    OPN_BKP_MODE=$(whiptail --menu "Origem do config.xml:" 0 60 2 \
      "url" "GitHub (privado) ou URL/pasta com listagem" \
      "local" "Arquivo/pasta local no Proxmox" \
      3>&2 2>&1 1>&3) || OPN_BKP_MODE="none"
    if [[ "$OPN_BKP_MODE" == "url" ]]; then
      OPN_BKP_URL=$(whiptail --inputbox "URL do config.xml, da pasta/tree no GitHub, ou do repositório:" 0 70 "${UFTM_BKP_URL:-}" 3>&2 2>&1 1>&3) || OPN_BKP_MODE="none"
    elif [[ "$OPN_BKP_MODE" == "local" ]]; then
      OPN_BKP_URL=$(whiptail --inputbox "Caminho completo do config.xml ou pasta no Proxmox:" 0 70 3>&2 2>&1 1>&3) || OPN_BKP_MODE="none"
    fi
    msg_warn "O PAT do GitHub (se precisar) é pedido na hora do download (etapa 3) -- nunca fica salvo no estado."
  fi

  state_set UFTM_OPN_STORAGE "$OPN_STORAGE"
  state_set UFTM_OPN_CPU "$OPN_CPU"
  state_set UFTM_OPN_RAM "$OPN_RAM"
  state_set UFTM_OPN_DISK "$OPN_DISK"
  state_set UFTM_OPN_VER "$OPN_VER"
  state_set UFTM_OPN_BKP_MODE "$OPN_BKP_MODE"
  state_set UFTM_OPN_BKP_URL "${OPN_BKP_URL:-}"
  state_set UFTM_OPNSENSE_PARAMS_DONE "1"
  msg_ok "Parâmetros da VM OPNsense coletados"
fi

# ═══════════════════════════════════════════════════════════════
# 8) Firewall: IPs WAN da UFTM autorizados a acessar o host
#    (NUNCA vai pro Git -- fica só no estado local deste host)
# ═══════════════════════════════════════════════════════════════
if [[ -z "${UFTM_FW_ALLOWED_IPS:-}" ]]; then
  whiptail --msgbox "Agora informe as faixas de IP WAN da UFTM que podem acessar este host (SSH, 8006, WireGuard, SNMP).\n\nUma por linha ou separadas por espaço. Ex:\n186.248.203.208/28\n200.131.62.125\n200.131.62.128/25\n\nEsses IPs NÃO vão para o repositório Git -- ficam só no estado local deste host." 0 78
  FW_IPS=$(whiptail --inputbox "Faixas de IP (separadas por espaço):" 0 78 \
    "186.248.203.208/28 200.131.62.125 200.131.62.128/25" 3>&2 2>&1 1>&3) || exit 1
  [[ -z "$FW_IPS" ]] && { msg_error "É necessário pelo menos uma faixa de IP autorizada."; exit 1; }
  state_set UFTM_FW_ALLOWED_IPS "$FW_IPS"
  msg_ok "Faixas de IP autorizadas gravadas no estado local"
fi

# ═══════════════════════════════════════════════════════════════
# Resumo final
# ═══════════════════════════════════════════════════════════════
state_load
SUMMARY="Host final: ${UFTM_HOSTNAME_FINAL}
IP WAN: ${UFTM_IP_WAN:-<${UFTM_WAN_MODE}>}
WG Porta/Tunnel: ${UFTM_WG_PORT} / ${UFTM_WG_TUNNEL_IP}
Domínio local: .${UFTM_DOMAIN}   IP gerência: ${UFTM_MGMT_IP}

Rede: WAN=${UFTM_WAN_MODE} (${UFTM_WAN_NIC}->${UFTM_WAN_BRIDGE})
      LAN trunk: ${UFTM_LAN_NIC}->${UFTM_LAN_BRIDGE}
      Console: ${UFTM_CONSOLE_BRIDGE:-<nenhum>}

VLANs: ${UFTM_SELECTED_VLANS}

OPNsense: ${UFTM_OPNSENSE}$( [[ "$UFTM_OPNSENSE" =~ ^[SsYy] ]] && echo " (${UFTM_OPN_CPU}vCPU/${UFTM_OPN_RAM}MB/${UFTM_OPN_DISK}, backup: ${UFTM_OPN_BKP_MODE})" )

Firewall: IPs autorizados definidos (não exibidos aqui por segurança)

A PARTIR DA ETAPA 4 (rede) A CONEXÃO COM A INTERNET DESTE LABORATÓRIO SERÁ
PERDIDA DE PROPÓSITO -- confirme que os downloads da etapa 3 já rodaram."

whiptail --msgbox "$SUMMARY" 0 78
CHOICE=$(whiptail --menu "O que deseja fazer?" 0 70 3 \
  "continuar" "Continuar com a instalação" \
  "refazer"   "Refazer o wizard do zero" \
  "cancelar"  "Cancelar (nada mais será feito)" \
  3>&2 2>&1 1>&3) || CHOICE="cancelar"

case "$CHOICE" in
  continuar)
    state_set UFTM_WIZARD_DONE "1"
    msg_ok "Wizard concluído -- prosseguindo para download de dependências"
    ;;
  refazer)
    rm -f "$UFTM_STATE_FILE"
    msg_warn "Estado apagado -- rode o wizard de novo do zero"
    exit 1
    ;;
  *)
    msg_error "Cancelado pelo usuário -- estado preservado em $UFTM_STATE_FILE para retomar depois"
    exit 1
    ;;
esac
