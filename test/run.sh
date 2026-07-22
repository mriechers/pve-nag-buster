#!/bin/sh
# Dependency-free test harness for pve-nag-buster.sh.
# Runs on any POSIX system with perl; no root, no host writes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FIXTURE="$HERE/fixtures/proxmoxlib.9.1.1.js"
FAIL=0
ok()    { echo "ok   - $1"; }
bad()   { echo "FAIL - $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2' want '$3')"; }

# Source the hook without running main()
export PVE_NAG_BUSTER_SOURCE=1
. "$REPO/pve-nag-buster.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- test sections are appended by later tasks ---

echo
if [ "$FAIL" = 0 ]; then echo "ALL PASS"; exit 0; else echo "SOME FAILED"; exit 1; fi
