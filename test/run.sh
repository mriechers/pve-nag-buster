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

# --- repos: deb822 disable + no-subscription creation ---
SRC="$WORK/sources"; mkdir -p "$SRC"
cat > "$SRC/pve-enterprise.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Enabled: true
EOF
SOURCES_DIR="$SRC" RELEASE=trixie manage_repos
check "enterprise disabled"                  "$(grep -c '^Enabled: false' "$SRC/pve-enterprise.sources")" "1"
check "no-subscription created"              "$( [ -f "$SRC/pve-no-subscription.sources" ] && echo yes || echo no )" "yes"
SOURCES_DIR="$SRC" RELEASE=trixie manage_repos
check "repos idempotent: single Enabled:false" "$(grep -c '^Enabled: false' "$SRC/pve-enterprise.sources")" "1"

# --- marker gate: repos untouched without marker, managed with it ---
SRC2="$WORK/sources2"; mkdir -p "$SRC2"
printf 'Types: deb\nEnabled: true\n' > "$SRC2/pve-enterprise.sources"
printf 'x\n' > "$WORK/nag_absent.js"
NAGFILE="$WORK/nag_absent.js" MARKER="$WORK/no-marker" SOURCES_DIR="$SRC2" main
check "no marker -> enterprise untouched"     "$(grep -c 'Enabled: true' "$SRC2/pve-enterprise.sources")" "1"
echo 'MANAGE_REPOS=1' > "$WORK/marker"
NAGFILE="$WORK/nag_absent.js" MARKER="$WORK/marker" SOURCES_DIR="$SRC2" RELEASE=trixie main
check "marker -> enterprise disabled"         "$(grep -c '^Enabled: false' "$SRC2/pve-enterprise.sources")" "1"

# --- install.sh smoke checks (no root needed) ---

# Decode the base64+xz offline blob embedded in install.sh directly, without
# `install.sh --emit` (which resets PATH to a hardened value excluding Homebrew's
# xz on macOS). python3+lzma is present on both macOS and Proxmox.
decode_blob() {
  awk '/base64 -d << /{f=1;next} /^YEET$/{f=0} f' "$REPO/install.sh" \
    | python3 -c 'import sys,base64,lzma; sys.stdout.buffer.write(lzma.decompress(base64.b64decode(sys.stdin.buffer.read())))'
}

check "install.sh syntax ok"     "$(sh -n "$REPO/install.sh" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
check "offline blob decodes to a hook" "$(decode_blob 2>/dev/null | head -1)" "#!/bin/sh"
check "unknown flag -> usage"    "$(sh "$REPO/install.sh" --bogus 2>/dev/null | grep -c Usage)" "1"

# --- offline blob invariant: embedded copy must equal the plaintext hook ---
blob_sha="$(decode_blob 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
file_sha="$(shasum -a 256 "$REPO/pve-nag-buster.sh" | cut -d' ' -f1)"
check "offline blob == plaintext hook" "$blob_sha" "$file_sha"

echo
if [ "$FAIL" = 0 ]; then echo "ALL PASS"; exit 0; else echo "SOME FAILED"; exit 1; fi
