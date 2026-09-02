#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: tteckster | MickLesk (CanbiZ)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# Modified for UFTM installation - 2026
# By Guilherme de Lima Gontijo - https://github.com/GlGontijo/UFTM-Proxmox-Casas

header_info() {
  clear
  cat <<"EOF"
    ____ _    ________   ____             __     ____           __        ____
   / __ \ |  / / ____/  / __ \____  _____/ /_   /  _/___  _____/ /_____ _/ / /
  / /_/ / | / / __/    / /_/ / __ \/ ___/ __/   / // __ \/ ___/ __/ __ `/ / /
 / ____/| |/ / /___   / ____/ /_/ (__  ) /_   _/ // / / (__  ) /_/ /_/ / / /
/_/     |___/_____/  /_/    \____/____/\__/  /___/_/ /_/____/\__/\__,_/_/_/

Alterado por Guilherme de Lima Gontijo - Set-2026
https://github.com/GlGontijo/UFTM-Proxmox-Casas
UFTM - Universidade Federal do Triangulo Mineiro

EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

set -euo pipefail
shopt -s inherit_errexit nullglob

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

# Telemetry
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func) 2>/dev/null || true
declare -f init_tool_telemetry &>/dev/null && init_tool_telemetry "post-pve-install" "pve"

get_pve_version() {
  local pve_ver
  pve_ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  echo "$pve_ver"
}

get_pve_major_minor() {
  local ver="$1"
  local major minor
  IFS='.' read -r major minor _ <<<"$ver"
  echo "$major $minor"
}

component_exists_in_sources() {
  local component="$1"
  local line comp
  while IFS= read -r line; do
    line="${line#*Components:}"
    for comp in $line; do
      [[ "$comp" == "$component" ]] && return 0
    done
  done < <(grep -h -E "^[^#]*Components:" /etc/apt/sources.list.d/*.sources 2>/dev/null)
  return 1
}

main() {
  header_info
  echo -e "\nThis script will Perform Post Install Routines.\n"
  while true; do
    read -p "Start the Proxmox VE Post Install Script (y/n)? " yn
    case $yn in
    [Yy]*) break ;;
    [Nn]*)
      clear
      exit
      ;;
    *) echo "Please answer yes or no." ;;
    esac
  done

  local PVE_VERSION PVE_MAJOR PVE_MINOR
  PVE_VERSION="$(get_pve_version)"
  read -r PVE_MAJOR PVE_MINOR <<<"$(get_pve_major_minor "$PVE_VERSION")"

# UFTM project only suports Proxmox 9.0-9.2.x
  if [[ "$PVE_MAJOR" != "9" ]]; then
    msg_error "Unsupported Proxmox $PVE_MAJOR version"
    msg_error "Only Proxmox 9.0-9.2.x is currently supported"
    exit 105
  else 
    if ((PVE_MINOR < 0 || PVE_MINOR > 2)); then
      msg_error "Only Proxmox 9.0-9.2.x is currently supported"
      exit 105
    fi
    start_routines_9 "$PVE_MINOR"
  fi
}

# Will not have version 8 routines
#start_routines_8() {}

start_routines_9() {
  local PVE_MINOR="${1:-0}"
  header_info

  # check if deb822 Sources (*.sources) exist
  check_and_disable_legacy_sources() {
    local LEGACY_COUNT=0
    local listfile="/etc/apt/sources.list"
    # Check sources.list
    if [[ -f "$listfile" ]] && grep -qE '^\s*deb ' "$listfile"; then
      ((++LEGACY_COUNT))
    fi
    # Check .list files
    local list_files
    list_files=$(find /etc/apt/sources.list.d/ -type f -name "*.list" 2>/dev/null)
    if [[ -n "$list_files" ]]; then
      LEGACY_COUNT=$((LEGACY_COUNT + $(echo "$list_files" | wc -l)))
    fi
    if ((LEGACY_COUNT > 0)); then
      # Show summary to user
      local MSG="Legacy APT sources found:\n"
      [[ -f "$listfile" ]] && MSG+=" - /etc/apt/sources.list\n"
      [[ -n "$list_files" ]] && MSG+="$(echo "$list_files" | sed 's|^| - |')\n"
      MSG+="\nThese will be disabled (commented out/renamed) so that ONLY deb822 .sources format is used.\n\nRequired for Proxmox VE 9."
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "Disabling legacy sources" \
        --msgbox "$MSG" 0 0

      # Backup and disable sources.list
      if [[ -f "$listfile" ]] && grep -qE '^\s*deb ' "$listfile"; then
        cp "$listfile" "$listfile.bak"
        sed -i '/^\s*deb /s/^/# Disabled by Proxmox Helper Script /' "$listfile"
        msg_ok "Disabled entries in sources.list (backup: sources.list.bak)"
      fi
      # Rename all .list files to .list.bak
      if [[ -n "$list_files" ]]; then
        while IFS= read -r f; do
          mv "$f" "$f.bak"
        done <<<"$list_files"
        msg_ok "Renamed legacy .list files to .bak"
      fi
    fi
  }

  if find /etc/apt/sources.list.d/ -maxdepth 1 -name '*.sources' | grep -q .; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "Deb822 sources detected" \
      --msgbox "Modern deb822 sources (*.sources) already exist.\n\nNo changes to sources format required." 12 65 || true
    check_and_disable_legacy_sources
  else
    check_and_disable_legacy_sources
    # === Trixie/9.x: deb822 .sources ===
    local MSG="The package manager will use the correct sources to update and install packages on your Proxmox VE 9 server."
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "SOURCES" \
      --msgbox "$MSG" 0 0
    msg_info "Correcting Proxmox VE Sources (deb822)"
    # remove all existing .list files
    rm -f /etc/apt/sources.list.d/*.list
    # remove bookworm and proxmox entries from sources.list (if it exists)
    if [ -f /etc/apt/sources.list ]; then
      sed -i '/proxmox/d;/bookworm/d' /etc/apt/sources.list
    fi
    # Create new deb822 sources
    cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    msg_ok "Corrected Proxmox VE 9 (Trixie) Sources"
  fi

  # ---- PVE-ENTERPRISE ----
  # No PVE-Enterprise for now
  if component_exists_in_sources "pve-enterprise"; then
    local MSG="The 'pve-enterprise' repository found:\n"
    MSG+="\nIt is only available to users who have purchased a Proxmox VE subscription.\n\nSo wil be deleted."
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "PVE-ENTERPRISE" \
      --msgbox "$MSG" 0 0 
    msg_info "Deleting 'pve-enterprise' repository file"
    for file in /etc/apt/sources.list.d/*.sources; do
      if grep -q "Components:.*pve-enterprise" "$file"; then
        rm -f "$file"
      fi
    done
    msg_ok "Deleted 'pve-enterprise' repository file"
    # ---- CEPH-ENTERPRISE ----
    if grep -q "enterprise.proxmox.com.*ceph" /etc/apt/sources.list.d/*.sources 2>/dev/null; then
      msg_info "Deleting 'ceph enterprise' repository file"
      for file in /etc/apt/sources.list.d/*.sources; do
        if grep -q "enterprise.proxmox.com.*ceph" "$file"; then
          rm -f "$file"
        fi
      done
      msg_ok "Deleted 'ceph enterprise' repository file"
    fi
  fi

  # ---- PVE-NO-SUBSCRIPTION ----
  REPO_FILE=""
  REPO_ACTIVE=0
  REPO_COMMENTED=0
  for file in /etc/apt/sources.list.d/*.sources; do
    if grep -q "Components:.*pve-no-subscription" "$file"; then
      REPO_FILE="$file"
      if grep -E '^[^#]*Components:.*pve-no-subscription' "$file" >/dev/null; then
        REPO_ACTIVE=1
      elif grep -E '^#.*Components:.*pve-no-subscription' "$file" >/dev/null; then
        REPO_COMMENTED=1
      fi
      break
    fi
  done

  if [[ "$REPO_ACTIVE" -eq 1 ]]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "PVE-NO-SUBSCRIPTION" \
      --msgbox "Kept 'pve-no-subscription' repository" 0 0

  elif [[ "$REPO_COMMENTED" -eq 1 ]]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "PVE-NO-SUBSCRIPTION" \
      --msgbox "The 'pve-no-subscription' repository is currently DISABLED (commented out).\n\nIt provides access to all of the open-source components of Proxmox VE.\n\nThis will be enabled. (Uncomment)" 0 0
    msg_info "Enabling (uncommenting) 'pve-no-subscription' repository"
    sed -i '/^#\s*Types:/,/^$/s/^#\s*//' "$REPO_FILE"
    msg_ok "Enabled 'pve-no-subscription' repository"
  else
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "PVE-NO-SUBSCRIPTION" \
      --msgbox "The 'pve-no-subscription' repository provides access to all of the open-source components of Proxmox VE.\n\nAddind 'pve-no-subscription' repository (deb822)." 0 0
    msg_info "Adding 'pve-no-subscription' repository (deb822)"
    cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    msg_ok "Added 'pve-no-subscription' repository"
  fi

# CEPH and TEST repositories will not be modified. 

  post_routines_common
}

post_routines_common() {
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "SUBSCRIPTION NAG" \
    --msgbox "This will disable the nag message reminding you to purchase a subscription every time you log in to the web interface." 18 80
  whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox \
    --title "Support Subscriptions" "Supporting the software's development team is essential. Check their official website's Support Subscriptions for pricing. Without their dedicated work, we wouldn't have this exceptional software." 10 58
  msg_info "Disabling subscription nag"
  # Create external script, this is needed because DPkg::Post-Invoke is fidly with quote interpretation
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    // --- Remove subscription dialogs ---" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const text = (dialog.textContent || '').toLowerCase();" \
      "      if (text.includes('subscription')) {" \
      "        dialog.remove();" \
      "        console.log('Removed subscription dialog');" \
      "      }" \
      "    });" \
      "" \
      "    // --- Remove subscription cards, but keep Reboot/Shutdown/Console ---" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const text = (card.textContent || '').toLowerCase();" \
      "      const hasButton = card.querySelector('button');" \
      "      if (!hasButton && text.includes('subscription')) {" \
      "        card.remove();" \
      "        console.log('Removed subscription card');" \
      "      }" \
      "    });" \
      "  }" \
      "" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" \
      "" >> "$MOBILE_TPL"
fi
EOF
  chmod 755 /usr/local/bin/pve-remove-nag.sh

  cat >/etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
  chmod 644 /etc/apt/apt.conf.d/no-nag-script

  msg_ok "Disabled subscription nag (Delete browser cache)"
  
  apt --reinstall install proxmox-widget-toolkit &>/dev/null || msg_error "Widget toolkit reinstall failed"

  CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "UPDATE" --menu "\nUpdate Proxmox VE now?" 11 58 2 \
    "yes" " " \
    "no" " " 3>&2 2>&1 1>&3)
  case $CHOICE in
  yes)
    msg_info "Updating Proxmox VE (Patience)"
    apt update &>/dev/null || msg_error "apt update failed"
    apt -y dist-upgrade &>/dev/null || msg_error "apt dist-upgrade failed"
    msg_ok "Updated Proxmox VE"
    ;;
  no) msg_error "Selected no to Updating Proxmox VE" ;;
  esac

  # Final message for all hosts in cluster and browser cache
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Post-Install Reminder" --msgbox \
    "IMPORTANT:

If you have multiple Proxmox VE hosts in a cluster, please make sure to run this script on every node individually.

After completing these steps, it is strongly recommended to REBOOT your node.

After the upgrade or post-install routines, always clear your browser cache or perform a hard reload (Ctrl+Shift+R) before using the Proxmox VE Web UI to avoid UI display issues.
" 20 80

  CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "REBOOT" --menu "\nReboot Proxmox VE now? (recommended)" 11 58 2 \
    "yes" " " \
    "no" " " 3>&2 2>&1 1>&3)
  case $CHOICE in
  yes)
    msg_info "Rebooting Proxmox VE"
    sleep 2
    msg_ok "Completed Post Install Routines"
    reboot
    ;;
  no)
    msg_error "Selected no to Rebooting Proxmox VE (Reboot recommended)"
    msg_ok "Completed Post Install Routines"
    ;;
  esac
}

main
