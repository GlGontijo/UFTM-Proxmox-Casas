#!/bin/bash
#
# install-evpn-vlan-bind.sh (v2 -- auto-discovery)
#
# Descobre automaticamente:
#   - quais VNETs pertencem a zonas EVPN e qual a tag (VLAN) de cada uma
#     (lendo /etc/pve/sdn/zones.cfg e /etc/pve/sdn/vnets.cfg)
#   - qual trunk fisico vlan-aware carrega aquela tag
#     (lendo bridge-vids em /etc/network/interfaces)
#
# E gera/ativa o pacote completo: subinterfaces no /etc/network/interfaces,
# script de bind idempotente, systemd service (cobre boot) e regra udev
# (cobre recriacao em runtime -- SDN Apply, restart do FRR, etc).
#
# Uso:
#   bash install-evpn-vlan-bind.sh            # auto-detect tudo e aplica
#   bash install-evpn-vlan-bind.sh --dry-run  # so mostra o que faria, nao aplica
#
# Ajustes finos (opcionais, edite as variaveis abaixo se precisar):
#   EXCLUDE_VLANS   -- tags para pular mesmo se detectadas
#   FORCE_TRUNK     -- resolve ambiguidade (tag em >1 trunk): "1022:vmbr3 1054:vmbr3"
#   INTERFACES_ROOT -- prefixo de path, usado so pelos testes (nao mexa em producao)

# Este script usa recursos exclusivos do bash (arrays associativos, [[ ]],
# EUID, mapfile). Se for chamado via "sh" (dash no Debian/Proxmox), a linha
# abaixo se re-executa sozinha usando bash. Isto e' POSIX-sh valido, entao
# funciona mesmo antes do "set -euo pipefail" (que e' bashismo).
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# ============================================================
# AJUSTES OPCIONAIS
# ============================================================
MTU=1360
EXCLUDE_VLANS=""      # ex: "1019 1620" -- tags a NUNCA amarrar (ex: VLANs de DMZ/WAN)
FORCE_TRUNK=""        # ex: "1022:vmbr3" -- resolve ambiguidade tag -> trunk
INTERFACES_ROOT=""    # nao mude isso; usado internamente pelo self-test

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

ZONES_CFG="${INTERFACES_ROOT}/etc/pve/sdn/zones.cfg"
VNETS_CFG="${INTERFACES_ROOT}/etc/pve/sdn/vnets.cfg"
INTERFACES_FILE="${INTERFACES_ROOT}/etc/network/interfaces"
BIND_SCRIPT="${INTERFACES_ROOT}/usr/local/sbin/evpn-vlan-bind.sh"
SYSTEMD_UNIT="${INTERFACES_ROOT}/etc/systemd/system/evpn-vlan-bind.service"
UDEV_RULE="${INTERFACES_ROOT}/etc/udev/rules.d/70-evpn-vnet-bind.rules"

if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then
  echo "Rode como root (ou use --dry-run para so simular)." >&2
  exit 1
fi

for f in "$ZONES_CFG" "$VNETS_CFG" "$INTERFACES_FILE"; do
  [[ -f "$f" ]] || { echo "Arquivo nao encontrado: $f" >&2; exit 1; }
done

echo "== EVPN VLAN Bind Installer (auto-discovery) =="
echo

# ------------------------------------------------------------
# 1. Zonas do tipo EVPN
# ------------------------------------------------------------
mapfile -t EVPN_ZONES < <(awk '/^evpn:[[:space:]]/{print $2}' "$ZONES_CFG")
if [ ${#EVPN_ZONES[@]} -eq 0 ]; then
  echo "Nenhuma zone tipo 'evpn' encontrada em $ZONES_CFG" >&2
  exit 1
fi
echo "Zonas EVPN: ${EVPN_ZONES[*]}"

is_evpn_zone() {
  local z="$1"
  for e in "${EVPN_ZONES[@]}"; do [[ "$e" == "$z" ]] && return 0; done
  return 1
}

# ------------------------------------------------------------
# 2. VNETs pertencentes as zonas EVPN, com sua tag
# ------------------------------------------------------------
declare -A VNET_TAG
cur_vnet="" cur_zone="" cur_tag=""
flush_vnet() {
  if [[ -n "$cur_vnet" && -n "$cur_tag" ]] && is_evpn_zone "$cur_zone"; then
    VNET_TAG["$cur_vnet"]="$cur_tag"
  fi
}
while IFS= read -r line; do
  if [[ "$line" =~ ^vnet:[[:space:]]+(.+)$ ]]; then
    flush_vnet
    cur_vnet="${BASH_REMATCH[1]}"; cur_zone=""; cur_tag=""
  elif [[ "$line" =~ ^[[:space:]]+zone[[:space:]]+(.+)$ ]]; then
    cur_zone="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^[[:space:]]+tag[[:space:]]+([0-9]+)$ ]]; then
    cur_tag="${BASH_REMATCH[1]}"
  fi
done < "$VNETS_CFG"
flush_vnet

if [ ${#VNET_TAG[@]} -eq 0 ]; then
  echo "Nenhuma VNET com tag encontrada nas zonas EVPN." >&2
  exit 1
fi
echo "VNETs EVPN detectadas:"
for v in "${!VNET_TAG[@]}"; do echo "  $v -> tag ${VNET_TAG[$v]}"; done
echo

# ------------------------------------------------------------
# 3. Trunks vlan-aware e suas bridge-vids (com suporte a ranges "X-Y")
# ------------------------------------------------------------
declare -A TAG_BRIDGES   # tag -> "vmbrX vmbrY ..."
expand_range() {
  local spec="$1"
  if [[ "$spec" == *-* ]]; then seq "${spec%-*}" "${spec#*-}"; else echo "$spec"; fi
}
cur_iface="" is_vlan_aware=0 vids=""
process_iface() {
  if [[ -n "$cur_iface" && "$is_vlan_aware" -eq 1 && -n "$vids" ]]; then
    for tok in $vids; do
      for t in $(expand_range "$tok"); do
        TAG_BRIDGES["$t"]="${TAG_BRIDGES[$t]:-} $cur_iface"
      done
    done
  fi
}
while IFS= read -r line; do
  if [[ "$line" =~ ^iface[[:space:]]+(vmbr[0-9]+)[[:space:]]+inet ]]; then
    process_iface
    cur_iface="${BASH_REMATCH[1]}"; is_vlan_aware=0; vids=""
  elif [[ "$line" =~ bridge-vlan-aware[[:space:]]+yes ]]; then
    is_vlan_aware=1
  elif [[ "$line" =~ bridge-vids[[:space:]]+(.+)$ ]]; then
    vids="${BASH_REMATCH[1]}"
  elif [[ -z "${line// /}" ]]; then
    process_iface; cur_iface=""; is_vlan_aware=0; vids=""
  fi
done < "$INTERFACES_FILE"
process_iface

# ------------------------------------------------------------
# 4. Resolver bind final: tag -> (trunk escolhido, vnet)
# ------------------------------------------------------------
declare -A FINAL_BINDS   # "vmbrX.tag" -> vnetTag
declare -A FORCE_MAP
for pair in $FORCE_TRUNK; do
  FORCE_MAP["${pair%%:*}"]="${pair#*:}"
done

echo "Resolucao trunk x tag:"
for vnet in "${!VNET_TAG[@]}"; do
  tag="${VNET_TAG[$vnet]}"

  skip=0
  for e in $EXCLUDE_VLANS; do [[ "$e" == "$tag" ]] && skip=1; done
  if [[ $skip -eq 1 ]]; then
    echo "  tag $tag ($vnet): EXCLUIDA por EXCLUDE_VLANS -- pulando"
    continue
  fi

  bridges="$(echo "${TAG_BRIDGES[$tag]:-}" | xargs -n1 2>/dev/null | sort -u | xargs || true)"
  count=$(echo "$bridges" | wc -w)
  chosen="${FORCE_MAP[$tag]:-}"

  if [[ -n "$chosen" ]]; then
    echo "  tag $tag ($vnet): forcado manualmente -> $chosen (FORCE_TRUNK)"
  elif [[ $count -eq 1 ]]; then
    chosen="$bridges"
    echo "  tag $tag ($vnet): trunk unico detectado -> $chosen"
  elif [[ $count -eq 0 ]]; then
    echo "  tag $tag ($vnet): AVISO -- nenhum trunk vlan-aware carrega essa tag neste host. Pulando."
    continue
  else
    echo "  tag $tag ($vnet): AMBIGUO -- encontrada em multiplos trunks ($bridges)."
    echo "                 Resolva definindo FORCE_TRUNK=\"$tag:vmbrX\" no topo do script e rode de novo. Pulando por ora."
    continue
  fi

  FINAL_BINDS["${chosen}.${tag}"]="$vnet"
done
echo

if [ ${#FINAL_BINDS[@]} -eq 0 ]; then
  echo "Nada para amarrar (nenhum bind resolvido). Nada foi alterado." >&2
  exit 1
fi

echo "Binds finais que serao aplicados:"
for k in "${!FINAL_BINDS[@]}"; do echo "  $k -> ${FINAL_BINDS[$k]}"; done
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[--dry-run] Nada foi escrito em disco. Rode sem --dry-run para aplicar."
  exit 0
fi

# ------------------------------------------------------------
# 5. Gerar bloco no /etc/network/interfaces
# ------------------------------------------------------------
STAMP_START="# BEGIN evpn-vlan-bind (managed block, gerado por install-evpn-vlan-bind.sh)"
STAMP_END="# END evpn-vlan-bind"

TMP_BLOCK=$(mktemp)
{
  echo "$STAMP_START"
  for k in "${!FINAL_BINDS[@]}"; do
    cat <<EOF

auto ${k}
iface ${k} inet manual
        mtu ${MTU}
        requires ${FINAL_BINDS[$k]}
EOF
  done
  echo
  echo "$STAMP_END"
} > "$TMP_BLOCK"

cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%s)"
if grep -qF "$STAMP_START" "$INTERFACES_FILE"; then
  sed -i "/$(printf '%s' "$STAMP_START" | sed 's/[.[\*^$/]/\\&/g')/,/$(printf '%s' "$STAMP_END" | sed 's/[.[\*^$/]/\\&/g')/d" "$INTERFACES_FILE"
fi
cat "$TMP_BLOCK" >> "$INTERFACES_FILE"
rm -f "$TMP_BLOCK"
echo ">> $INTERFACES_FILE atualizado (backup: ${INTERFACES_FILE}.bak.<timestamp>)"

# ------------------------------------------------------------
# 6. Script de bind
# ------------------------------------------------------------
{
  echo "#!/bin/bash"
  echo "# Gerado por install-evpn-vlan-bind.sh -- NAO EDITAR MANUALMENTE"
  echo
  echo "declare -A binds=("
  for k in "${!FINAL_BINDS[@]}"; do
    echo "  [${k}]=${FINAL_BINDS[$k]}"
  done
  echo ")"
  cat <<'EOF'

fail=0
for iface in "${!binds[@]}"; do
  vnet="${binds[$iface]}"
  ok=0
  for i in {1..30}; do
    if ip link show "$vnet" &>/dev/null; then
      if ip link show "$iface" &>/dev/null; then
        current_master=$(ip -o link show "$iface" | grep -oP 'master \K\S+' || true)
        if [ "$current_master" != "$vnet" ]; then
          ip link set "$iface" master "$vnet"
          echo "OK: $iface -> $vnet (aplicado)"
        else
          echo "OK: $iface -> $vnet (ja correto)"
        fi
      else
        echo "FALHOU: $iface nao existe (subinterface VLAN nao subiu)"
        fail=1
      fi
      ok=1
      break
    fi
    sleep 1
  done
  if [ "$ok" -eq 0 ]; then
    echo "FALHOU: $vnet nunca apareceu para $iface"
    fail=1
  fi
done
exit $fail
EOF
} > "$BIND_SCRIPT"
chmod +x "$BIND_SCRIPT"
echo ">> $BIND_SCRIPT gerado"

# ------------------------------------------------------------
# 7. systemd service + regra udev
# ------------------------------------------------------------
cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Bind VLAN subinterfaces to EVPN VNET bridges
After=networking.service frr.service
Wants=frr.service
Requires=networking.service

[Service]
Type=oneshot
ExecStart=${BIND_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
echo ">> $SYSTEMD_UNIT gerado"

cat > "$UDEV_RULE" <<EOF
# Gerado por install-evpn-vlan-bind.sh -- NAO EDITAR MANUALMENTE
#
# Duas frentes de recriacao precisam ser cobertas:
#   1. o lado da SDN (vnet<TAG>) e recriado -- ex: "Apply" na SDN, restart do FRR
#   2. o lado do trunk fisico (vmbrX.TAG) e recriado -- ex: ifreload apos editar
#      /etc/network/interfaces
# Se so cobrirmos o (1), o caso (2) fica sem master apos qualquer ifreload.
#
# IMPORTANTE: o RUN+= aqui NAO chama o script de bind diretamente. Processos
# disparados pelo udev rodam com PATH minimo (o "ip" pode nao ser encontrado)
# e devem ser rapidos/nao-bloqueantes (nosso script tem retry com sleep, o
# que e desaconselhado dentro do worker do udev). Por isso disparamos o
# systemd service (ambiente completo, roda fora do worker do udev).
# Tem que ser "restart", nao "start": como e Type=oneshot com
# RemainAfterExit=yes, depois do boot a unit fica "active (exited)" e
# "systemctl start" nao reexecuta o ExecStart nesse estado -- so "restart" forca.
ACTION=="add", SUBSYSTEM=="net", KERNEL=="vnet*", RUN+="/usr/bin/systemctl --no-block restart evpn-vlan-bind.service"
EOF
for k in "${!FINAL_BINDS[@]}"; do
  echo "ACTION==\"add\", SUBSYSTEM==\"net\", KERNEL==\"${k}\", RUN+=\"/usr/bin/systemctl --no-block restart evpn-vlan-bind.service\"" >> "$UDEV_RULE"
done
echo ">> $UDEV_RULE gerado (${#FINAL_BINDS[@]} regra(s) de trunk + 1 regra generica de vnet, todas via systemctl restart)"

systemctl daemon-reload
systemctl enable evpn-vlan-bind.service
udevadm control --reload

echo
echo "== Instalacao concluida =="
echo
echo "PROXIMOS PASSOS MANUAIS:"
echo "  1. diff ${INTERFACES_FILE}.bak.* $INTERFACES_FILE"
for k in "${!FINAL_BINDS[@]}"; do
  echo "  2. ifdown ${k}; ifup ${k} --verbose"
done
echo "  3. systemctl start evpn-vlan-bind.service && systemctl status evpn-vlan-bind.service"
for k in "${!FINAL_BINDS[@]}"; do
  echo "  4. ip link show ${k} | grep -oP 'mtu \\d+|master \\S+'"
done
echo "  5. So depois de validar a quente, agende um REBOOT para confirmar o boot do zero."
