#!/bin/bash
#
# uninstall-evpn-vlan-bind.sh
#
# Remove o pacote evpn-vlan-bind deste host: desabilita o service, remove a
# regra udev e o script de bind. NAO remove automaticamente o bloco do
# /etc/network/interfaces (edite manualmente, o bloco esta marcado com
# comentarios "BEGIN/END evpn-vlan-bind" para facilitar localizar e apagar).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Rode como root." >&2
  exit 1
fi

BIND_SCRIPT="/usr/local/sbin/evpn-vlan-bind.sh"
SYSTEMD_UNIT="/etc/systemd/system/evpn-vlan-bind.service"
UDEV_RULE="/etc/udev/rules.d/70-evpn-vnet-bind.rules"

systemctl disable --now evpn-vlan-bind.service 2>/dev/null || true
rm -f "$SYSTEMD_UNIT" "$UDEV_RULE" "$BIND_SCRIPT"
systemctl daemon-reload
udevadm control --reload

echo "Removido: $BIND_SCRIPT, $SYSTEMD_UNIT, $UDEV_RULE"
echo
echo "ATENCAO: o bloco em /etc/network/interfaces (entre '# BEGIN evpn-vlan-bind'"
echo "e '# END evpn-vlan-bind') NAO foi removido automaticamente. Edite manualmente"
echo "se quiser desfazer tambem as subinterfaces VLAN."
