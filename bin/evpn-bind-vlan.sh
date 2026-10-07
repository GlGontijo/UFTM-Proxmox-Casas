#!/usr/bin/env bash
#
# bin/evpn-bind-vlan.sh
# Os vnets EVPN (vnet1010, vnet1011...) são bridges Linux criados pelo SDN,
# mas SEM uplink físico -- pra tráfego local da VLAN no switch físico chegar
# até o fabric VXLAN, é preciso escravizar uma sub-interface 802.1Q da
# bridge de trunk (ex: vmbr2.1010) dentro do vnet correspondente.
#
# Dificuldades já mapeadas no projeto:
#   1) ifupdown2 reconcilia os membros da bridge a cada `ifreload`, desfazendo
#      qualquer `ip link set master` feito manualmente/fora do config declarado.
#   2) os dispositivos vnetXXXX só são materializados pelo FRR/zebra DEPOIS
#      que networking.service termina -- um post-up não é suficiente.
#   3) [FIX] a sub-interface 802.1Q criada aqui via `ip link add ... type vlan`
#      fica fora do ifupdown2 -- diferente de uma subinterface declarada em
#      /etc/network/interfaces, ela NÃO programa sozinha a membership do VID
#      na entrada "self" da bridge trunk vlan-aware. Sem essa entrada, a
#      bridge flooda broadcast normalmente (por isso o ARP request passa),
#      mas não sabe encaminhar o unicast de volta pras portas físicas (por
#      isso a resposta do ARP morre). Corrigido abaixo com
#      `bridge vlan add vid ... dev ... self` a cada reconciliação, e com
#      MTU 1360 explícito pra bater com o padrão VXLAN/WireGuard do projeto.
#   4) [FIX] antes, `reconcile()` rodava inteiro (todas as VLANs) a cada
#      evento de `ip monitor link` do host -- inclusive tap de VM subindo/
#      descendo sem relação nenhuma com essas VLANs. Isso gastava CPU à toa
#      em hosts com bastante churn de VM. Agora filtra a linha do monitor
#      pelo nome das interfaces relevantes (phys/vnet do vlan-binds.conf)
#      antes de reconciliar, igual o script anterior (pré-wizard) já fazia.
#
# Solução: um serviço systemd persistente (Type=simple) que roda `ip monitor
# link` e reconcilia os binds sempre que um vnet aparece/some ou o master é
# perdido -- sem polling, sem hacks de timer.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_cmd ip bridge
state_load

: "${UFTM_LAN_BRIDGE:?Rode bin/wizard.sh + network-install.sh antes}"
: "${UFTM_SELECTED_VLANS:?Rode bin/wizard.sh antes}"

BIND_CONF="$UFTM_ETC_DIR/vlan-binds.conf"
BIND_SCRIPT="/usr/local/bin/uftm-evpn-bind-vlan.sh"
UNIT_FILE="/etc/systemd/system/uftm-evpn-bind-vlan.service"

# ── Detecção de ambiguidade: mais de uma bridge trunk vlan-aware no host ──
mapfile -t TRUNK_BRIDGES < <(for b in /sys/class/net/*/bridge; do
    br=$(basename "$(dirname "$b")")
    [[ -f "/sys/class/net/$br/bridge/vlan_filtering" ]] || continue
    [[ "$(cat "/sys/class/net/$br/bridge/vlan_filtering")" == "1" ]] && echo "$br"
  done)

if [[ "${#TRUNK_BRIDGES[@]}" -gt 1 && -z "${FORCE_TRUNK:-}" ]]; then
  msg_error "Mais de uma bridge trunk (vlan-aware) detectada: ${TRUNK_BRIDGES[*]}."
  msg_error "Ambíguo qual delas deve receber as sub-interfaces das VLANs do fabric."
  msg_error "Refaça com: FORCE_TRUNK=<bridge> $0"
  exit 1
fi
LAN_TRUNK="${FORCE_TRUNK:-$UFTM_LAN_BRIDGE}"

if ! ip link show "$LAN_TRUNK" &>/dev/null; then
  msg_error "Bridge de trunk '$LAN_TRUNK' não existe neste host. Rode network-install.sh primeiro."
  exit 1
fi

# ── Gera o arquivo de mapeamento (phys_sub_iface vnet_bridge vlan) ────────
mkdir -p "$UFTM_ETC_DIR"
backup_if_exists "$BIND_CONF"
: >"$BIND_CONF"
for vlan in $UFTM_SELECTED_VLANS; do
  [[ -z "$vlan" ]] && continue
  echo "${LAN_TRUNK}.${vlan} vnet${vlan} ${vlan}" >>"$BIND_CONF"
done
msg_ok "Mapeamento gravado em $BIND_CONF ($(wc -l <"$BIND_CONF") VLAN(s))"

# ── Script de bind/reconciliação (roda no boot e a cada evento netlink) ──
cat >"$BIND_SCRIPT" <<'BINDEOF'
#!/bin/bash
# uftm-evpn-bind-vlan.sh
# Reconciliador de binds VLAN física <-> vnet EVPN + MSS clamping por VLAN.
# Sem polling: bloqueia em `ip monitor link` e age só em eventos relevantes.
set -u
CONF="/etc/uftm-proxmox-casas/vlan-binds.conf"
LOG_TAG="uftm-evpn-bind"
SUBIF_MTU=1360
MSS=$((SUBIF_MTU - 40))
MSS_CHAIN="UFTM-MSS"

ipt() { iptables -w 5 -t mangle "$@"; }

relevant_names() {
  [[ -f "$CONF" ]] || return
  while read -r phys vnet vlan; do
    [[ -z "$phys" || "$phys" == \#* ]] && continue
    echo "$phys"; echo "$vnet"
  done <"$CONF"
}

# ── MSS clamping (tráfego bridged => physdev + valor fixo) ──────────
# Só as sub-interfaces das VLANs do fabric são casadas; a bridge principal
# e as VLANs fora do EVPN não são afetadas. Não altera MTU de nada.
mss_init() {
  modprobe br_netfilter 2>/dev/null || true
  [[ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null)" == "1" ]] \
    || logger -t "$LOG_TAG" "AVISO: bridge-nf-call-iptables != 1, MSS clamp não verá tráfego bridged"
  ipt -N "$MSS_CHAIN" 2>/dev/null || true
  ipt -F "$MSS_CHAIN"   # limpa regras de VLANs removidas (só no início do serviço)
  ipt -C FORWARD -j "$MSS_CHAIN" 2>/dev/null || ipt -I FORWARD 1 -j "$MSS_CHAIN"
}

ensure_mss() {
  local phys="$1" dir
  for dir in in out; do
    local rule=("$MSS_CHAIN" -m physdev "--physdev-$dir" "$phys"
                -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS")
    ipt -C "${rule[@]}" 2>/dev/null && continue
    ipt -A "${rule[@]}" && logger -t "$LOG_TAG" "MSS $MSS ($dir) em $phys"
  done
}

reconcile() {
  [[ -f "$CONF" ]] || { logger -t "$LOG_TAG" "config ausente: $CONF"; return; }
  # garante a jump caso algo tenha recriado a chain FORWARD
  ipt -C FORWARD -j "$MSS_CHAIN" 2>/dev/null || ipt -I FORWARD 1 -j "$MSS_CHAIN" 2>/dev/null

  while read -r phys vnet vlan; do
    [[ -z "$phys" || "$phys" == \#* ]] && continue

    ensure_mss "$phys"

    local_parent="${phys%.*}"
    if ! ip link show "$phys" &>/dev/null; then
      if ip link show "$local_parent" &>/dev/null; then
        ip link add link "$local_parent" name "$phys" type vlan id "$vlan" 2>/dev/null \
          && logger -t "$LOG_TAG" "criada sub-interface $phys (vlan $vlan)"
      else
        continue
      fi
    fi
    ip link set "$phys" up 2>/dev/null
    ip link set "$phys" mtu "$SUBIF_MTU" 2>/dev/null   # só a sub-interface

    if ip link show "$local_parent" &>/dev/null; then
      bridge vlan add vid "$vlan" dev "$local_parent" self 2>/dev/null \
        && logger -t "$LOG_TAG" "self-vlan $vlan garantida em $local_parent"
    fi

    if ip link show "$vnet" &>/dev/null; then
      cur_master=$(ip -o link show "$phys" | grep -oP 'master \K\S+' || true)
      if [[ "$cur_master" != "$vnet" ]]; then
        ip link set "$phys" master "$vnet" \
          && logger -t "$LOG_TAG" "$phys -> master $vnet (vlan $vlan)"
      fi
    fi
  done <"$CONF"
}

logger -t "$LOG_TAG" "iniciando reconciliação inicial (MSS=$MSS)"
mss_init
reconcile

mapfile -t RELEVANT_NAMES < <(relevant_names)
logger -t "$LOG_TAG" "monitorando eventos netlink -- filtrando por: ${RELEVANT_NAMES[*]}"
ip monitor link 2>/dev/null | while read -r line; do
  match=0
  for name in "${RELEVANT_NAMES[@]}"; do
    [[ "$line" == *"$name"* ]] || continue
    match=1; break
  done
  [[ "$match" -eq 1 ]] || continue
  reconcile
done
BINDEOF
chmod 0755 "$BIND_SCRIPT"
msg_ok "Script de reconciliação instalado em $BIND_SCRIPT"

# ── Unidade systemd persistente ───────────────────────────────────
cat >"$UNIT_FILE" <<EOF
[Unit]
Description=UFTM - Bind persistente das VLANs de trunk nos vnets EVPN
After=networking.service frr.service pve-cluster.service
Wants=frr.service

[Service]
Type=simple
ExecStart=$BIND_SCRIPT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now uftm-evpn-bind-vlan.service
msg_ok "Serviço uftm-evpn-bind-vlan habilitado e iniciado"
systemctl --no-pager --full status uftm-evpn-bind-vlan.service | head -n 8 || true

msg_ok "evpn-bind-vlan.sh concluído"
state_mark_step "evpn-bind-vlan"
