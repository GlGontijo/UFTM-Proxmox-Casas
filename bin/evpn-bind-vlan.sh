#!/usr/bin/env bash
#
# bin/evpn-bind-vlan.sh
# Os vnets EVPN (vnet1010, vnet1011...) são bridges Linux criados pelo SDN,
# mas SEM uplink físico -- pra tráfego local da VLAN no switch físico chegar
# até o fabric VXLAN, é preciso escravizar uma sub-interface 802.1Q da
# bridge de trunk (ex: vmbr3.1010) dentro do vnet correspondente.
#
# Duas dificuldades já mapeadas no projeto:
#   1) ifupdown2 reconcilia os membros da bridge a cada `ifreload`, desfazendo
#      qualquer `ip link set master` feito manualmente/fora do config declarado.
#   2) os dispositivos vnetXXXX só são materializados pelo FRR/zebra DEPOIS
#      que networking.service termina -- um post-up não é suficiente.
#
# Solução: um serviço systemd persistente (Type=simple) que roda `ip monitor
# link` e reconcilia os binds sempre que um vnet aparece/some ou o master é
# perdido -- sem polling, sem hacks de timer.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_cmd ip bridge

[[ -f "$UFTM_ETC_DIR/network.env" ]] && source "$UFTM_ETC_DIR/network.env"
[[ -f "$UFTM_ETC_DIR/vlans.env" ]] && source "$UFTM_ETC_DIR/vlans.env"

: "${UFTM_LAN_BRIDGE:?UFTM_LAN_BRIDGE não definido -- rode network-install.sh antes}"
: "${UFTM_SELECTED_VLANS:?UFTM_SELECTED_VLANS não definido -- rode sdn-install.sh antes}"

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
# Reconciliador de binds VLAN física <-> vnet EVPN. Não usa polling: fica
# bloqueado em `ip monitor link` e só age quando o netlink emite um evento.
set -u
CONF="/etc/uftm-proxmox-casas/vlan-binds.conf"
LOG_TAG="uftm-evpn-bind"

reconcile() {
  [[ -f "$CONF" ]] || { logger -t "$LOG_TAG" "config ausente: $CONF"; return; }
  while read -r phys vnet vlan; do
    [[ -z "$phys" || "$phys" == \#* ]] && continue

    # cria a sub-interface 802.1Q se ainda não existir (a bridge trunk pai
    # precisa já existir; se não existir ainda, tenta de novo no próximo evento)
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

    # só escraviza quando o vnet (bridge alvo) já existe -- ele é criado
    # tardiamente pelo FRR/zebra, depois do networking.service
    if ip link show "$vnet" &>/dev/null; then
      cur_master=$(ip -o link show "$phys" | grep -oP 'master \K\S+' || true)
      if [[ "$cur_master" != "$vnet" ]]; then
        ip link set "$phys" master "$vnet" \
          && logger -t "$LOG_TAG" "$phys -> master $vnet (vlan $vlan)"
      fi
    fi
  done <"$CONF"
}

logger -t "$LOG_TAG" "iniciando reconciliação inicial"
reconcile

logger -t "$LOG_TAG" "monitorando eventos netlink (ip monitor link)"
ip monitor link 2>/dev/null | while read -r _; do
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
