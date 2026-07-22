#!/bin/sh
#
# pve-nag-buster.sh (v05) https://github.com/mriechers/pve-nag-buster
# Copyright (C) 2019 /u/seaQueue (reddit.com/u/seaQueue)
#
# Removes Proxmox VE license nags automatically after updates.
# Homelab fork: robust fail-safe checked_command patch (PVE 8/9) + opt-in repos.
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

SCRIPT="$(basename "$0")"

# Neutralize the checked_command "No valid subscription" modal: replace the
# whole `if (...) { Ext.Msg.show(...) } else { orig_cmd(); }` conditional with a
# bare `orig_cmd();`. One all-or-nothing multi-line substitution — if the block
# does not match (future PVE refactor) nothing is written (fail-safe).
# Returns 0 if the file changed, 1 otherwise.
patch_nag() {
  nagfile="$1"
  [ -f "$nagfile" ] || return 1
  command -v perl >/dev/null 2>&1 || { echo "$SCRIPT: perl missing, skipping nag patch" >&2; return 1; }

  tmp="$(mktemp)" || return 1
  cp "$nagfile" "$tmp" || { rm -f "$tmp"; return 1; }

  perl -0777 -i -pe 's/if\s*\(\s*res === null\s*\|\|\s*res === undefined\s*\|\|\s*!res\s*\|\|\s*res\.data\.status\.toLowerCase\(\)\s*!==\s*\x27active\x27\s*\)\s*\{.*?\}\s*else\s*\{\s*orig_cmd\(\);\s*\}/orig_cmd();/s' "$tmp"

  if cmp -s "$nagfile" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  cp "$nagfile" "$nagfile.orig"
  cat "$tmp" > "$nagfile"
  rm -f "$tmp"
  echo "$SCRIPT: Nag neutralized in $nagfile"
  return 0
}

main() {
  nagfile="${NAGFILE:-/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js}"
  if patch_nag "$nagfile"; then
    command -v systemctl >/dev/null 2>&1 && systemctl restart pveproxy.service
  fi
  return 0
}

# Run unless sourced for tests (test harness sets PVE_NAG_BUSTER_SOURCE=1)
[ "${PVE_NAG_BUSTER_SOURCE:-0}" = "1" ] || main "$@"
