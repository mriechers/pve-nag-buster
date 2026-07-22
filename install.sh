#!/bin/sh
# shellcheck disable=SC2064
set -eu

# pve-nag-buster (v05) https://github.com/mriechers/pve-nag-buster
# Copyright (C) 2019 /u/seaQueue (reddit.com/u/seaQueue)
#
# Removes Proxmox VE 6.x+ license nags automatically after updates
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

# ensure a predictable environment
PATH=/usr/sbin:/usr/bin:/sbin:/bin
\unalias -a

# installer main body:
_main() {
  REPOS=0
  MODE=""
  for a in "$@"; do
    case "$a" in
      --repos) REPOS=1 ;;
      --emit | --uninstall | --install | --offline) MODE="$a" ;;
      "") : ;;
      *) _usage; exit 0 ;;
    esac
  done

  case "$MODE" in
    "--emit")
      # dump the stored copy to stdout so you can verify it; no root needed
      emit_script
      ;;
    "--uninstall")
      assert_root
      _uninstall
      ;;
    "--install" | "--offline" | "")
      assert_root
      _install "$MODE"
      ;;
  esac
  exit 0
}

_uninstall() {
  set -x
  rm -f "/etc/apt/apt.conf.d/86pve-nags"
  rm -f "/usr/share/pve-nag-buster.sh"
  rm -f "/etc/default/pve-nag-buster"

  NAGFILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  if [ -f "$NAGFILE.orig" ]; then
    mv -f "$NAGFILE.orig" "$NAGFILE"
    command -v systemctl >/dev/null 2>&1 && systemctl restart pveproxy.service
  fi
  set +x

  echo "Removed dpkg hooks, hook script, and marker; restored proxmoxlib.js from backup if present."
  echo "Repo .sources files were left as-is — review /etc/apt/sources.list.d/ if desired."
}

_install() {
  # create hooks and no-subscription repo list, install hook script, run once

  # repo handling is opt-in (--repos); the hook script performs it when the
  # marker is present. Default installs leave apt sources untouched.
  if [ "${REPOS:-0}" = "1" ]; then
    echo "Enabling opt-in repo management (--repos) ..."
    printf 'MANAGE_REPOS=1\n' > "/etc/default/pve-nag-buster"
  fi

  # create dpkg pre/post install hooks for persistence
  echo "Creating dpkg hooks in /etc/apt/apt.conf.d ..."
  cat <<- 'EOF' > "/etc/apt/apt.conf.d/86pve-nags"
	DPkg::Pre-Install-Pkgs {
	    "while read -r pkg; do case $pkg in *proxmox-widget-toolkit* | *pve-manager*) touch /tmp/.pve-nag-buster && exit 0; esac done < /dev/stdin";
	};

	DPkg::Post-Invoke {
	    "[ -f /tmp/.pve-nag-buster ] && { /usr/share/pve-nag-buster.sh; rm -f /tmp/.pve-nag-buster; }; exit 0";
	};
	EOF

  # install the hook script
  temp=''
  if [ "$1" = "--offline" ]; then
    # packed script requested
    temp="$(mktemp)" && trap "rm -f $temp" EXIT
    emit_script > "$temp"
  elif [ -f "pve-nag-buster.sh" ]; then
    # local copy available
    temp="pve-nag-buster.sh"
  else
    # fetch from github
    echo "Fetching hook script from GitHub ..."
    tempd="$(mktemp -d)" &&
      trap "echo 'Cleaning up temporary files ...'; rm -f $tempd/*; rmdir $tempd" EXIT
    temp="$tempd/pve-nag-buster.sh"
    wget https://raw.githubusercontent.com/mriechers/pve-nag-buster/master/pve-nag-buster.sh \
      -q --show-progress -O "$temp"
  fi
  echo "Installing hook script as /usr/share/pve-nag-buster.sh"
  install -o root -m 0550 "$temp" "/usr/share/pve-nag-buster.sh"

  echo "Running patch script"
  /usr/share/pve-nag-buster.sh

  return 0
}

# emit a stored copy of pve-nag-buster.sh offline -- this is intended to be used during
# offline provisioning where we don't have access to github or a full cloned copy of the
# project

# run 'install.sh --emit' to dump stored script to stdout

# Important: if you're not me you should probably decode this and read it to make sure I'm not doing
#            something malicious like mining dogecoin or stealing your valuable cat pictures

# pve-nag-buster.sh (v05) encoded below:

emit_script() {
  base64 -d << 'YEET' | unxz
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
YEET
}

assert_root() { [ "$(id -u)" -eq '0' ] || { echo "This action requires root." && exit 1; }; }
_usage() { echo "Usage: $(basename "$0") (--install|--offline|--repos|--uninstall|--emit)"; }

_main "$@"
