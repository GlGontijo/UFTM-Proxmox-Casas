#!/usr/bin/env bash
#
# bin/sdn-install.sh
# ETAPA 6 do fluxo. Configura, via API nativa do Proxmox (pvesh), o fabric
# WireGuard, o controller EVPN, a zone EVPN/VXLAN, os vnets (VLANs) e a
# zone/vnet/subnet de SNAT. Só cai para edição direta de /etc/pve/sdn/*.cfg
# se a chamada via pvesh falhar -- e mesmo assim nunca toca em
# /etc/network/interfaces.d/sdn (regenerado pelo próprio Proxmox a partir
# de /etc/pve/sdn).
#
# Não pergunta nada -- tudo (hub/spoke, VLANs) já foi decidido no wizard
# (etapa 2) e vem do arquivo de estado.
#
# Sobre aplicar a cada mudança vs. só no final: optamos por UM ÚNICO
# `pvesh set /cluster/sdn` no final, depois de todos os creates (fabric, nó,
# controller, zone, vnets, subnet). O SDN do Proxmox já foi desenhado pra
# acumular mudanças pendentes e aplicar tudo de uma vez (é o que o botão
# "Apply" da GUI faz) -- aplicar a cada objeto criado só adiciona overhead e
# abre uma janela de "aplicação parcial" se um passo do meio falhar.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_cmd pvesh wg jq
state_load

FABRIC_ID="WG-FAB"
HUB_HOSTNAME="pve-vpnserver"
HUB_ENDPOINT="pgdprotic.uftm.edu.br:51820"
HUB_PUBKEY="Rln4PMSU5niFAJ8zGEawTQuibSjlXwffSERgIMe3QBY="
HUB_LOOPBACK_CIDR="10.255.255.1/32"
FABRIC_ALLOWED_IPS="10.255.255.0/24"
EVPN_ASN=65000
EVPN_CONTROLLER="evpnctl"
EVPN_ZONE="evpnzn"
EVPN_VRF_VXLAN=100
EVPN_ZONE_MTU=1360
SNAT_ZONE="snatzn"
SNAT_VNET="vnetsnat"
SNAT_SUBNET_CIDR="172.31.0.0/30"
SNAT_GATEWAY="172.31.0.1"

: "${UFTM_WG_PK:?Rode bin/wizard.sh primeiro (etapa 2)}"
: "${UFTM_WG_PORT:?Rode bin/wizard.sh primeiro (etapa 2)}"
: "${UFTM_WG_TUNNEL_IP:?Rode bin/wizard.sh primeiro (etapa 2)}"
: "${UFTM_SELECTED_VLANS:?Rode bin/wizard.sh primeiro (etapa 2)}"
IS_HUB="${UFTM_IS_HUB:-n}"

pvesh_try() {
  # pvesh_try <method> <path> [args...] -- retorna 0/1, nunca aborta o script
  local method="$1" path="$2"; shift 2
  pvesh "$method" "$path" "$@" 2>/tmp/uftm-pvesh-err.log
}

api_apply() {
  msg_info "Aplicando alterações do SDN (pvesh set /cluster/sdn)"
  if pvesh set /cluster/sdn >/tmp/uftm-pvesh-apply.log 2>&1; then
    msg_ok "SDN aplicado"
  else
    msg_error "Falha ao aplicar SDN -- veja /tmp/uftm-pvesh-apply.log"
    cat /tmp/uftm-pvesh-apply.log >&2
  fi
}

WG_PUBKEY="$(echo "$UFTM_WG_PK" | wg pubkey)"
msg_ok "Chave pública derivada: $WG_PUBKEY"

# ── 1) Fabric WireGuard ─────────────────────────────────────────
# Confirmado via `pvesh usage /cluster/sdn/fabrics/fabric --command create
# --verbose`: o endpoint de criação é /cluster/sdn/fabrics/fabric (não
# /cluster/sdn/fabrics), os parâmetros são --id/--protocol/--ip_prefix, e
# --persistent_keepalive só existe condicionalmente quando protocol=wireguard.
# --id tem regex [a-zA-Z0-9][a-zA-Z0-9-]{0,6}[a-zA-Z0-9] -- MÁXIMO 8
# CARACTERES. "WG-FAB" (6) cabe; não aumente o nome do fabric além disso.
msg_info "Verificando fabric $FABRIC_ID"
if pvesh_try get "/cluster/sdn/fabrics/fabric/$FABRIC_ID" >/dev/null; then
  msg_ok "Fabric $FABRIC_ID já existe"
else
  if pvesh_try create /cluster/sdn/fabrics/fabric \
      -id "$FABRIC_ID" -protocol wireguard \
      -ip_prefix "$FABRIC_ALLOWED_IPS" -persistent_keepalive 10 >/dev/null; then
    msg_ok "Fabric $FABRIC_ID criado via pvesh"
  else
    msg_warn "pvesh falhou ao criar o fabric (log em /tmp/uftm-pvesh-err.log)."
    cat /tmp/uftm-pvesh-err.log >&2 || true
  fi
fi

# ── 2) Nó do fabric: hub (external, referência) ou spoke (internal) ──
# Confirmado via `pvesh ls /cluster/sdn/fabrics/node`: nós NÃO se criam em
# /cluster/sdn/fabrics/node direto (isso não tem handler de create) -- cada
# fabric tem sua própria coleção de nós em
# /cluster/sdn/fabrics/node/<FABRIC_ID> (ex: /cluster/sdn/fabrics/node/WG-FAB),
# e É ALI que se faz o create.
#
# ATENÇÃO -- os nomes de parâmetro abaixo (-node/-allowed-ips/-role/
# -interfaces/-peers/-endpoint) ainda são um "melhor palpite" baseado no
# formato do fabrics.cfg antigo, e NÃO foram confirmados contra
# `pvesh usage /cluster/sdn/fabrics/node/WG-FAB --command create --verbose`.
# Assim que esse comando rodar, ajusto esta seção para os nomes reais.
NODE_COLLECTION="/cluster/sdn/fabrics/node/${FABRIC_ID}"
NODE_ID="${FABRIC_ID}_${UFTM_HOSTNAME}"

if [[ "$IS_HUB" == "s" ]]; then
  msg_info "Registrando nó HUB ($NODE_ID)"
  ENDPOINT_STR="${UFTM_IP_WAN:+${UFTM_IP_WAN}}:${UFTM_WG_PORT}"
  IFACE_STR="name=wg0,listen_port=${UFTM_WG_PORT},public_key=${WG_PUBKEY},ip=${HUB_LOOPBACK_CIDR}"
  if pvesh_try create "$NODE_COLLECTION" \
      -node "$NODE_ID" -allowed-ips "$FABRIC_ALLOWED_IPS" \
      -role external -interfaces "$IFACE_STR" >/dev/null; then
    msg_ok "Nó hub registrado"
  else
    msg_warn "pvesh falhou ao registrar o nó hub -- verifique /tmp/uftm-pvesh-err.log (schema ainda não confirmado, ver comentário acima)"
  fi
else
  msg_info "Registrando nó SPOKE ($NODE_ID), peer = hub ($HUB_HOSTNAME)"
  IFACE_STR="name=wg0,listen_port=${UFTM_WG_PORT},public_key=${WG_PUBKEY},ip=${UFTM_WG_TUNNEL_IP}/24"
  PEER_STR="type=external,node=${HUB_HOSTNAME},iface=wg0"
  if pvesh_try create "$NODE_COLLECTION" \
      -node "$NODE_ID" -allowed-ips "$FABRIC_ALLOWED_IPS" \
      -endpoint "${UFTM_IP_WAN:-auto}" \
      -role internal -interfaces "$IFACE_STR" -peers "$PEER_STR" >/dev/null; then
    msg_ok "Nó spoke registrado"
  else
    msg_warn "pvesh falhou ao registrar o nó spoke -- verifique /tmp/uftm-pvesh-err.log (schema ainda não confirmado, ver comentário acima)"
    msg_warn "Confirme manualmente se o hub ($HUB_HOSTNAME) já tem a chave pública deste spoke autorizada."
  fi
fi

# A chave PRIVADA nunca é passada por linha de comando (fica em /proc/*/cmdline
# visível a outros processos). O fabric aceita a chave via arquivo/stdin na UI;
# via pvesh, gravamos apenas se houver um parâmetro de arquivo suportado --
# caso a versão da API exija a private_key inline, isso é feito manualmente
# na GUI (Datacenter > SDN > Fabrics) por enquanto, e sinalizado aqui:
msg_warn "Se a API não aceitar private_key via arquivo nesta versão do PVE, informe-a manualmente em Datacenter > SDN > Fabrics > $NODE_ID (não fica em nenhum arquivo do repo)."

# ── 3) Controller EVPN ──────────────────────────────────────────
msg_info "Verificando controller EVPN $EVPN_CONTROLLER"
if pvesh_try get "/cluster/sdn/controllers/$EVPN_CONTROLLER" >/dev/null; then
  msg_ok "Controller $EVPN_CONTROLLER já existe -- adicionando este nó aos peers se necessário"
  CUR_PEERS=$(pvesh get "/cluster/sdn/controllers/$EVPN_CONTROLLER" --output-format json 2>/dev/null | jq -r '.peers // ""')
  if [[ "$CUR_PEERS" != *"$UFTM_WG_TUNNEL_IP"* ]]; then
    NEW_PEERS="${CUR_PEERS:+${CUR_PEERS},}${UFTM_WG_TUNNEL_IP}"
    pvesh_try set "/cluster/sdn/controllers/$EVPN_CONTROLLER" -peers "$NEW_PEERS" >/dev/null \
      && msg_ok "Peer $UFTM_WG_TUNNEL_IP adicionado ao controller" \
      || msg_warn "Falha ao atualizar peers do controller -- adicione manualmente: $NEW_PEERS"
  fi
else
  if pvesh_try create /cluster/sdn/controllers \
      -controller "$EVPN_CONTROLLER" -type evpn -asn "$EVPN_ASN" \
      -peers "$UFTM_WG_TUNNEL_IP" >/dev/null; then
    msg_ok "Controller $EVPN_CONTROLLER criado"
  else
    msg_warn "Falha ao criar controller -- verifique /tmp/uftm-pvesh-err.log"
  fi
fi

# ── 4) Zone EVPN ─────────────────────────────────────────────────
msg_info "Verificando zone $EVPN_ZONE"
if pvesh_try get "/cluster/sdn/zones/$EVPN_ZONE" >/dev/null; then
  msg_ok "Zone $EVPN_ZONE já existe"
else
  if pvesh_try create /cluster/sdn/zones \
      -zone "$EVPN_ZONE" -type evpn -controller "$EVPN_CONTROLLER" \
      -vrf-vxlan "$EVPN_VRF_VXLAN" -ipam pve -mtu "$EVPN_ZONE_MTU" >/dev/null; then
    msg_ok "Zone $EVPN_ZONE criada (MTU $EVPN_ZONE_MTU)"
  else
    msg_warn "Falha ao criar zone EVPN -- verifique /tmp/uftm-pvesh-err.log"
  fi
fi

# ── 5) VLANs / vnets (lista já decidida no wizard) ───────────────
SELECTED_VLANS="$UFTM_SELECTED_VLANS"

for vlan in $SELECTED_VLANS; do
  [[ -z "$vlan" ]] && continue
  vnet="vnet${vlan}"
  msg_info "Verificando vnet $vnet (VLAN $vlan)"
  if pvesh_try get "/cluster/sdn/vnets/$vnet" >/dev/null; then
    msg_ok "vnet $vnet já existe"
  else
    if pvesh_try create /cluster/sdn/vnets \
        -vnet "$vnet" -zone "$EVPN_ZONE" -tag "$vlan" \
        -alias "Vnet Bridge Vlan${vlan}" >/dev/null; then
      msg_ok "vnet $vnet criado"
    else
      msg_warn "Falha ao criar vnet $vnet -- verifique /tmp/uftm-pvesh-err.log"
    fi
  fi
done

# ── 6) Zone/vnet/subnet de SNAT ──────────────────────────────────
msg_info "Verificando zone de SNAT $SNAT_ZONE"
if ! pvesh_try get "/cluster/sdn/zones/$SNAT_ZONE" >/dev/null; then
  pvesh_try create /cluster/sdn/zones -zone "$SNAT_ZONE" -type simple -ipam pve >/dev/null \
    && msg_ok "Zone $SNAT_ZONE criada" \
    || msg_warn "Falha ao criar zone SNAT -- verifique /tmp/uftm-pvesh-err.log"
else
  msg_ok "Zone $SNAT_ZONE já existe"
fi

msg_info "Verificando vnet de SNAT $SNAT_VNET"
if ! pvesh_try get "/cluster/sdn/vnets/$SNAT_VNET" >/dev/null; then
  pvesh_try create /cluster/sdn/vnets -vnet "$SNAT_VNET" -zone "$SNAT_ZONE" \
    -alias "SNAT to VM Interfaces" >/dev/null \
    && msg_ok "vnet $SNAT_VNET criado" \
    || msg_warn "Falha ao criar vnet SNAT -- verifique /tmp/uftm-pvesh-err.log"
else
  msg_ok "vnet $SNAT_VNET já existe"
fi

SNAT_SUBNET_ID="${SNAT_ZONE}-$(echo "$SNAT_SUBNET_CIDR" | tr '/' '-')"
msg_info "Verificando subnet de SNAT $SNAT_SUBNET_ID"
if ! pvesh_try get "/cluster/sdn/vnets/$SNAT_VNET/subnets/$SNAT_SUBNET_ID" >/dev/null; then
  pvesh_try create "/cluster/sdn/vnets/$SNAT_VNET/subnets" \
    -subnet "$SNAT_SUBNET_CIDR" -type subnet -gateway "$SNAT_GATEWAY" -snat 1 >/dev/null \
    && msg_ok "subnet SNAT criada ($SNAT_SUBNET_CIDR, gw $SNAT_GATEWAY)" \
    || msg_warn "Falha ao criar subnet SNAT -- verifique /tmp/uftm-pvesh-err.log"
else
  msg_ok "subnet SNAT já existe"
fi

# ── 7) Aplica tudo (um único apply no final -- ver nota no topo) ────
api_apply

# ── 8) reresolve-dns: reagenda resolução do endpoint do peer ─────
# (o hook if-up que reinicia wg0 quando pppoe0 sobe já foi instalado por
# network-install.sh -- não duplicamos aqui.)
REDNS_SRC="/usr/share/doc/wireguard-tools/examples/reresolve-dns/reresolve-dns.sh"
WG_CONF="/etc/wireguard/proxmox/wg0.conf"
if [[ -f "$REDNS_SRC" ]]; then
  install -m 0755 "$REDNS_SRC" /usr/local/bin/uftm-reresolve-dns.sh
  cat >/etc/systemd/system/uftm-reresolve-dns.service <<EOF
[Unit]
Description=UFTM - Reresolve endpoint DNS do WireGuard (wg0)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/uftm-reresolve-dns.sh $WG_CONF
EOF
  cat >/etc/systemd/system/uftm-reresolve-dns.timer <<'EOF'
[Unit]
Description=UFTM - Reresolve DNS do WireGuard periodicamente

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now uftm-reresolve-dns.timer
  msg_ok "Timer uftm-reresolve-dns habilitado (a cada 5min, arquivo $WG_CONF)"
else
  msg_warn "$REDNS_SRC não encontrado (pacote wireguard-tools?) -- pulei o agendamento de reresolve-dns."
fi

state_mark_step "sdn-install"
msg_ok "sdn-install.sh concluído"
msg_warn "Diagnósticos pendentes conhecidos: Hold Timer Expired no BGP com pve-odonto (jitter PPPoE) e MTU do wg0 (SDN Fabric ainda não expõe campo de MTU para WireGuard) -- acompanhar separadamente."
