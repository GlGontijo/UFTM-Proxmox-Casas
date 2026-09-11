#!/usr/bin/env bash
#
# bin/hostname-and-restart.sh
# ETAPA 5 do fluxo. Aplica o hostname definitivo, grava o IP de gerência +
# domínio local (.uftm por padrão) em /etc/hosts -- o Proxmox depende dessa
# entrada pra subir corretamente -- e reinicia os serviços de rede e do
# próprio Proxmox, equivalente a um reboot só pra esses efeitos.
#
# Roda DEPOIS de network-install.sh (etapa 4) de propósito: mudar o
# hostname/reiniciar o networking ANTES da rede final estar escrita faria a
# máquina cair de volta pro DHCP do laboratório e perder a config nova.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
state_load

: "${UFTM_HOSTNAME_FINAL:?Rode bin/wizard.sh primeiro (etapa 2)}"
: "${UFTM_MGMT_IP:?Rode bin/wizard.sh primeiro (etapa 2) -- IP de gerência ausente}"

DOMAIN="${UFTM_DOMAIN:-uftm}"
FQDN="${UFTM_HOSTNAME_FINAL}.${DOMAIN}"
OLD_HOSTNAME="$(hostname)"

# ── 1) /etc/hosts: entrada de gerência que o Proxmox precisa pra subir ──
HOSTS_FILE="/etc/hosts"
backup_if_exists "$HOSTS_FILE"

# Remove qualquer linha anterior referenciando o hostname antigo OU o novo
# (idempotente -- evita duplicar se rodar de novo), preservando o resto do
# arquivo intacto.
grep -vE "(^|[[:space:]])(${OLD_HOSTNAME}|${UFTM_HOSTNAME_FINAL})([[:space:]]|\.${DOMAIN}|$)" "$HOSTS_FILE" >"${HOSTS_FILE}.tmp" || true
mv "${HOSTS_FILE}.tmp" "$HOSTS_FILE"

# Remove uma eventual entrada solta de 127.0.1.1 (padrão Debian) pro
# hostname antigo, pra não conflitar com a entrada de gerência nova.
sed -i "/^127\.0\.1\.1[[:space:]]/d" "$HOSTS_FILE"

printf '%s\t%s %s\n' "$UFTM_MGMT_IP" "$FQDN" "$UFTM_HOSTNAME_FINAL" >>"$HOSTS_FILE"
msg_ok "/etc/hosts atualizado: $UFTM_MGMT_IP -> $FQDN ($UFTM_HOSTNAME_FINAL)"

# ── 2) Demais arquivos que citam o hostname antigo ────────────────
for f in /etc/hostname /etc/mailname /etc/postfix/main.cf; do
  if [[ -f "$f" ]] && grep -q "$OLD_HOSTNAME" "$f" 2>/dev/null; then
    backup_if_exists "$f"
    sed -i "s/${OLD_HOSTNAME}/${UFTM_HOSTNAME_FINAL}/g" "$f"
    msg_ok "Atualizado: $f"
  fi
done

# ── 3) Aplica o hostname ──────────────────────────────────────────
hostnamectl set-hostname "$UFTM_HOSTNAME_FINAL"
msg_ok "Hostname aplicado: $UFTM_HOSTNAME_FINAL (FQDN local: $FQDN)"

# ── 4) Reinicia rede + serviços do Proxmox (equivalente a um reboot
#      só pra estes efeitos, conforme a documentação do Proxmox) ────
msg_info "Reiniciando rede e serviços do Proxmox para o novo hostname"
systemctl restart networking.service
sleep 2
systemctl restart pvedaemon.service pveproxy.service pve-cluster.service pve-firewall.service 2>/dev/null || true
msg_ok "Serviços reiniciados"

state_mark_step "hostname-and-restart"
msg_ok "hostname-and-restart.sh concluído"
msg_warn "Se a sessão SSH atual cair agora, é esperado (mudança de hostname/rede) -- reconecte pelo novo IP de gerência: $UFTM_MGMT_IP"
