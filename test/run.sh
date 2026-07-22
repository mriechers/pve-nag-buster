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

# --- nag patch: correctness + isolation ---
t="$WORK/a.js"; cp "$FIXTURE" "$t"
patch_nag "$t"; rc=$?
check "patch_nag returns 0 on match"        "$rc" "0"
check "modal removed"                        "$(grep -c 'No valid subscription' "$t")" "0"
check "status flag kept"                     "$(grep -c "res.data.status.toLowerCase() !== 'active'" "$t")" "1"
check "backup created"                       "$( [ -f "$t.orig" ] && echo yes || echo no )" "yes"
check "backup == original fixture"           "$(cmp -s "$FIXTURE" "$t.orig" && echo yes || echo no)" "yes"
check "isolation: exactly 20 fewer lines"    "$(( $(wc -l < "$FIXTURE") - $(wc -l < "$t") ))" "20"

# --- idempotency ---
cp "$t" "$WORK/b.js"
patch_nag "$WORK/b.js"; rc=$?
check "patch_nag returns 1 when already patched" "$rc" "1"
check "no change on 2nd run"                  "$(cmp -s "$t" "$WORK/b.js" && echo yes || echo no)" "yes"

# --- fail-safe on absent pattern ---
printf 'nothing to see here\n' > "$WORK/c.js"
patch_nag "$WORK/c.js"; rc=$?
check "patch_nag returns 1 when pattern absent"  "$rc" "1"
check "no backup when nothing matched"        "$( [ -f "$WORK/c.js.orig" ] && echo yes || echo no )" "no"

echo
if [ "$FAIL" = 0 ]; then echo "ALL PASS"; exit 0; else echo "SOME FAILED"; exit 1; fi
