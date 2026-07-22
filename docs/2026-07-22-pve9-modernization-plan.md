# PVE 9 Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pve-nag-buster hook reliably neutralize the Proxmox VE 9.1 login subscription nag with a robust, fail-safe patch, keeping upstream's dpkg-hook + offline-blob architecture, with opt-in deb822 repo handling.

**Architecture:** The hook script (`pve-nag-buster.sh`) is refactored into sourceable POSIX-sh functions (`patch_nag`, `manage_repos`, `main`) so it can be unit-tested off-host against a captured `proxmoxlib.js` fixture. The nag patch is a single all-or-nothing multi-line Perl substitution on the `checked_command` conditional. `install.sh` gains a `--repos` opt-in that writes a marker the hook reads. `make-release.sh` re-packs the embedded offline copy.

**Tech Stack:** POSIX `/bin/sh`, `perl` (multi-line substitution), `xz`+`base64` (offline blob), plain-sh test harness (no bats dependency).

## Global Constraints

- Target host: Proxmox VE **9.1.1**, `proxmox-widget-toolkit 5.1.2`; support PVE 8+; do **not** support minified JS or PVE < 8.
- Hook script stays `#!/bin/sh` (POSIX), **no `set -e`** (a failed patch must never abort apt).
- Nag patch is **fail-safe**: no perfect match ⇒ write nothing, exit 0.
- Repo manipulation is **off by default**; only runs when `/etc/default/pve-nag-buster` contains `MANAGE_REPOS=1` (written by `install.sh --repos`).
- Invariant that must hold after any hook edit: `install.sh --emit` output is **byte-identical** to `pve-nag-buster.sh` (same sha256).
- Exact nag-patch Perl expression (verified against the live 9.1.1 file), use verbatim:
  ```
  s/if\s*\(\s*res === null\s*\|\|\s*res === undefined\s*\|\|\s*!res\s*\|\|\s*res\.data\.status\.toLowerCase\(\)\s*!==\s*\x27active\x27\s*\)\s*\{.*?\}\s*else\s*\{\s*orig_cmd\(\);\s*\}/orig_cmd();/s
  ```
- Fixture source (captured this session, sha256 `5ec66dda9533903a3d7d737ba4910c26545548e1b17f8617ba8ac363049d42f7`):
  `/private/tmp/claude-501/-Users-mriechers-Developer-homelab-pve-nag-buster/36a3c1ef-e2c5-4aab-ab72-caa86bf299d5/scratchpad/proxmoxlib.9.1.1.js`

---

## File Structure

| File | Responsibility |
|---|---|
| `pve-nag-buster.sh` | Hook script. Sourceable functions: `patch_nag` (nag), `_disable_deb822`/`_disable_list`/`manage_repos` (repos), `main` (orchestration + marker gate). |
| `install.sh` | Installer. Adds `--repos` (writes marker), gates repo work, restores backup on `--uninstall`, carries the offline blob. |
| `make-release.sh` | Re-packs the offline blob into `install.sh`. Unchanged mechanism; version bumped to v05. |
| `test/run.sh` | Dependency-free test harness; asserts patch correctness/isolation/idempotency/fail-safe, repo handling, marker gate, blob invariant. |
| `test/fixtures/proxmoxlib.9.1.1.js` | Captured live widget-toolkit file used as the patch target in tests. |
| `README.md` | Documents PVE 9 support, robust patch, `--repos`. |

---

### Task 1: Test scaffolding + fixture

**Files:**
- Create: `test/fixtures/proxmoxlib.9.1.1.js` (copied from scratchpad)
- Create: `test/run.sh`

- [ ] **Step 1: Copy the fixture into the repo and verify its checksum**

Run:
```bash
mkdir -p test/fixtures
cp "/private/tmp/claude-501/-Users-mriechers-Developer-homelab-pve-nag-buster/36a3c1ef-e2c5-4aab-ab72-caa86bf299d5/scratchpad/proxmoxlib.9.1.1.js" test/fixtures/
shasum -a 256 test/fixtures/proxmoxlib.9.1.1.js
```
Expected: hash is `5ec66dda9533903a3d7d737ba4910c26545548e1b17f8617ba8ac363049d42f7`.

- [ ] **Step 2: Create the harness skeleton with assert helpers**

Create `test/run.sh`:
```sh
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
```

- [ ] **Step 3: Make it executable and confirm it runs (it will fail to source until Task 2)**

Run: `chmod +x test/run.sh && sh test/run.sh; echo "exit=$?"`
Expected: errors sourcing `pve-nag-buster.sh` (script currently runs top-level code, no functions) — this is expected; Task 2 fixes it. Do not commit a green run yet.

- [ ] **Step 4: Commit the scaffolding**

```bash
git add test/fixtures/proxmoxlib.9.1.1.js test/run.sh
git commit -m "test: add fixture + harness skeleton for pve9 modernization"
```

---

### Task 2: Robust fail-safe nag patch

**Files:**
- Modify (replace whole file): `pve-nag-buster.sh`
- Modify (append test section): `test/run.sh`

**Interfaces:**
- Produces: `patch_nag "<file>"` → edits file in place, returns `0` if changed / `1` if not; writes `<file>.orig` backup only when it changes something. `main` → runs `patch_nag` on `${NAGFILE:-<default>}` and restarts pveproxy on change.
- Consumes: fixture at `test/fixtures/proxmoxlib.9.1.1.js`; source guard env `PVE_NAG_BUSTER_SOURCE=1`.

- [ ] **Step 1: Append the nag tests to `test/run.sh`** (before the final `echo`)

```sh
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
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `sh test/run.sh; echo "exit=$?"`
Expected: FAIL — sourcing errors or `patch_nag: not found`, exit=1.

- [ ] **Step 3: Replace `pve-nag-buster.sh` entirely with the refactored, testable version**

```sh
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
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `sh test/run.sh; echo "exit=$?"`
Expected: all nag lines `ok`, `ALL PASS`, exit=0.

- [ ] **Step 5: Commit**

```bash
git add pve-nag-buster.sh test/run.sh
git commit -m "feat: robust fail-safe checked_command nag patch (PVE 8/9)"
```

---

### Task 3: Opt-in deb822 repo handling + marker gate

**Files:**
- Modify: `pve-nag-buster.sh` (add repo functions; extend `main`)
- Modify (append test section): `test/run.sh`

**Interfaces:**
- Produces: `manage_repos` (reads `${SOURCES_DIR:-/etc/apt/sources.list.d}`, `${RELEASE:-<codename>}`) disables enterprise `pve-enterprise.sources`/`ceph.sources` (deb822 `Enabled: false`) and legacy `.list`, and creates `pve-no-subscription.sources` unless one already exists. `main` runs `manage_repos` only when `${MARKER:-/etc/default/pve-nag-buster}` exists and sets `MANAGE_REPOS=1`.
- Consumes: `patch_nag`/`main` from Task 2.

- [ ] **Step 1: Append repo + marker-gate tests to `test/run.sh`** (before the final `echo`)

```sh
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
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `sh test/run.sh; echo "exit=$?"`
Expected: FAIL — `manage_repos: not found`, exit=1 (Task 2 nag tests still pass).

- [ ] **Step 3: Insert the repo functions into `pve-nag-buster.sh` immediately above `main()`**

Add these three functions (place them after `patch_nag()`'s closing `}` and before `main()`):
```sh
# --- optional repo handling (deb822-aware, opt-in via marker) -------------
# Set `Enabled: false` in a deb822 .sources stanza (idempotent).
_disable_deb822() {
  f="$1"
  [ -f "$f" ] || return 0
  if grep -qi '^[[:space:]]*Enabled:[[:space:]]*true' "$f"; then
    sed -i 's/^[[:space:]]*[Ee]nabled:[[:space:]]*[Tt]rue/Enabled: false/' "$f"
    echo "$SCRIPT: disabled repo $f"
  elif ! grep -qi '^[[:space:]]*Enabled:' "$f"; then
    printf 'Enabled: false\n' >> "$f"
    echo "$SCRIPT: disabled repo $f (appended Enabled: false)"
  fi
}

# Rename a legacy .list repo out of the way (older hosts).
_disable_list() {
  base="$1"
  if [ -f "$base.list" ]; then
    mv -f "$base.list" "$base.disabled"
    echo "$SCRIPT: disabled legacy $base.list"
  fi
}

manage_repos() {
  dir="${SOURCES_DIR:-/etc/apt/sources.list.d}"
  _disable_deb822 "$dir/pve-enterprise.sources"
  _disable_deb822 "$dir/ceph.sources"
  _disable_list "$dir/pve-enterprise"
  _disable_list "$dir/ceph"

  if ! grep -rqsi 'pve-no-subscription' "$dir" 2>/dev/null; then
    release="${RELEASE:-$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-trixie}" )}"
    cat > "$dir/pve-no-subscription.sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $release
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    echo "$SCRIPT: wrote $dir/pve-no-subscription.sources"
  fi
}
```

- [ ] **Step 4: Replace `main()` in `pve-nag-buster.sh` with the marker-aware version**

Replace the existing `main() { ... }` block with:
```sh
main() {
  nagfile="${NAGFILE:-/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js}"
  marker="${MARKER:-/etc/default/pve-nag-buster}"

  if patch_nag "$nagfile"; then
    command -v systemctl >/dev/null 2>&1 && systemctl restart pveproxy.service
  fi

  if [ -f "$marker" ]; then
    MANAGE_REPOS=0
    . "$marker"
    [ "${MANAGE_REPOS:-0}" = "1" ] && manage_repos
  fi
  return 0
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `sh test/run.sh; echo "exit=$?"`
Expected: all lines `ok`, `ALL PASS`, exit=0.

- [ ] **Step 6: Commit**

```bash
git add pve-nag-buster.sh test/run.sh
git commit -m "feat: opt-in deb822 repo handling gated by /etc/default marker"
```

---

### Task 4: `install.sh` — `--repos` flag, marker, uninstall restore

**Files:**
- Modify: `install.sh` (`_main` arg parsing, `_install`, `_uninstall`)
- Modify (append test section): `test/run.sh`

**Interfaces:**
- Produces: `install.sh [--offline] [--repos]` installs hooks; `--repos` writes `/etc/default/pve-nag-buster` (`MANAGE_REPOS=1`). `install.sh --uninstall` removes hooks/script/marker and restores `proxmoxlib.js.orig`. `install.sh --emit` unchanged. Unknown flags → usage.
- Consumes: `emit_script`, `assert_root`, `_usage` (existing).

- [ ] **Step 1: Append installer smoke tests to `test/run.sh`** (before the final `echo`)

```sh
# --- install.sh smoke checks (no root needed) ---
check "install.sh syntax ok"     "$(sh -n "$REPO/install.sh" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
check "install.sh --emit shebang" "$(sh "$REPO/install.sh" --emit 2>/dev/null | head -1)" "#!/bin/sh"
check "unknown flag -> usage"    "$(sh "$REPO/install.sh" --bogus 2>/dev/null | grep -c Usage)" "1"
```

- [ ] **Step 2: Run to confirm the unknown-flag test fails** (current `install.sh` treats unknown flags via `*` → usage, but `--repos` is not yet handled and emit must still work)

Run: `sh test/run.sh 2>&1 | grep -E 'install.sh|FAIL'; echo "exit=${PIPESTATUS:-$?}"`
Expected: `install.sh --emit shebang` and syntax pass; proceed regardless — these lock current behavior before edits.

- [ ] **Step 3: Replace `_main()` in `install.sh` to parse `--repos` as a modifier**

Replace the existing `_main() { ... }` with:
```sh
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
```

- [ ] **Step 4: Update `_install()` — drop the stale `.list` creation, write the marker when `--repos`**

In `install.sh`, replace the block that begins `# create the pve-no-subscription list` and its `cat <<- EOF > ".../pve-no-subscription.list"` heredoc (through its closing `EOF`) with:
```sh
  # repo handling is opt-in (--repos); the hook script performs it when the
  # marker is present. Default installs leave apt sources untouched.
  if [ "${REPOS:-0}" = "1" ]; then
    echo "Enabling opt-in repo management (--repos) ..."
    printf 'MANAGE_REPOS=1\n' > "/etc/default/pve-nag-buster"
  fi
```
Leave the dpkg-hook creation, hook-script install (`install -o root -m 0550 ...`), and the final `Running patch script` / `/usr/share/pve-nag-buster.sh` invocation exactly as they are.

- [ ] **Step 5: Update `_uninstall()` to remove the marker and restore the backup**

Replace the existing `_uninstall() { ... }` with:
```sh
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
```

- [ ] **Step 6: Run the full harness to confirm nothing regressed**

Run: `sh test/run.sh; echo "exit=$?"`
Expected: `ALL PASS`, exit=0. (The offline-blob invariant test is added in Task 5; `--emit` here still emits the Task-2/3 hook, which is stale until re-packed — that mismatch is fixed and asserted in Task 5.)

- [ ] **Step 7: Commit**

```bash
git add install.sh test/run.sh
git commit -m "feat(install): --repos opt-in marker, backup restore on uninstall, drop stale .list creation"
```

---

### Task 5: Re-pack offline blob + assert blob==plaintext invariant

**Files:**
- Modify: `make-release.sh` (bump `_VERS`), correct fork URL in `install.sh`
- Modify: `install.sh` (embedded base64 block — regenerated by the script)
- Modify (append test section): `test/run.sh`

**Interfaces:**
- Produces: `install.sh` whose embedded blob decodes to the current `pve-nag-buster.sh`. Test `emit blob == plaintext hook`.
- Consumes: `make-release.sh` packing mechanism (heredoc markers `<< 'YEET'` / `^YEET$`).

- [ ] **Step 1: Append the blob-invariant test to `test/run.sh`** (before the final `echo`)

```sh
# --- offline blob invariant: emitted copy must equal the plaintext hook ---
emit_sha="$(sh "$REPO/install.sh" --emit 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
file_sha="$(shasum -a 256 "$REPO/pve-nag-buster.sh" | cut -d' ' -f1)"
check "emit blob == plaintext hook" "$emit_sha" "$file_sha"
```

- [ ] **Step 2: Run to confirm it fails** (blob still holds the old v04 hook)

Run: `sh test/run.sh 2>&1 | grep 'emit blob'; echo done`
Expected: `FAIL - emit blob == plaintext hook (...)`.

- [ ] **Step 3: Correct the fork URL and bump the version in `make-release.sh`**

In `install.sh`, change the wget fallback owner from upstream to this fork:
```sh
    wget https://raw.githubusercontent.com/mriechers/pve-nag-buster/master/pve-nag-buster.sh \
      -q --show-progress -O "$temp"
```
In `make-release.sh`, change the version line:
```sh
_VERS="v05"
```

- [ ] **Step 4: Run the packer and verify the invariant + inspect the diff**

Run:
```bash
./make-release.sh
diff <(sh install.sh --emit) pve-nag-buster.sh && echo "BLOB==PLAINTEXT ✓"
sh test/run.sh; echo "exit=$?"
```
Expected: `BLOB==PLAINTEXT ✓`; harness prints `ALL PASS`, exit=0. Also skim `git diff install.sh` to confirm only the base64 block, version strings, and the URL branch changed.

- [ ] **Step 5: Commit**

```bash
git add install.sh make-release.sh test/run.sh
git commit -m "build: re-pack offline blob for v05 hook; fix fork raw URL; assert blob invariant"
```

---

### Task 6: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the News + How-it-works + add a fork note**

Replace the `### News:` line's "Last updated for" value with:
```markdown
Last updated for: pve-manager/9.1.1 (proxmox-widget-toolkit 5.1.2)
```
Add, after the "How does it work?" paragraph:
```markdown
This homelab fork replaces the brittle string-swap with a **fail-safe patch** of the
`checked_command` function: if the expected code block isn't found (e.g. a future
Proxmox refactor) it changes nothing rather than corrupting `proxmoxlib.js`. Repo
handling is **opt-in** — run `sudo ./install.sh --repos` to also disable the
enterprise `.sources` (deb822) and add the no-subscription repo; the default install
touches only the nag.
```

- [ ] **Step 2: Verify the harness still passes and commit**

Run: `sh test/run.sh; echo "exit=$?"`
Expected: `ALL PASS`, exit=0.
```bash
git add README.md
git commit -m "docs: README for PVE 9 fail-safe patch + --repos"
```

---

## Post-implementation: on-host validation (not part of the automated harness)

Route through the `proxmox-guardian` per homelab convention before running on `proxmox-01`:
1. `scp` the branch (or `git pull` on host) and run `sudo ./install.sh` (nag-only).
2. Hard-refresh the web UI → nag gone; confirm `proxmoxlib.js.orig` exists.
3. `apt reinstall proxmox-widget-toolkit` → hook re-patches automatically (check journal / output).
4. `sudo ./install.sh --uninstall` → nag returns, marker gone, backup restored.

---

## Self-Review

**Spec coverage:**
- Preserved architecture (flags, persistence, blob) → Tasks 2/4/5. ✅
- Robust fail-safe nag patch, backup, restart-on-change, idempotency → Task 2. ✅
- Opt-in deb822 repos + marker gate → Tasks 3/4. ✅
- Uninstall removes marker + restores `.orig` → Task 4. ✅
- Testing (patch/isolation/failsafe/idempotency/repos/marker/blob) → Tasks 1–5. ✅
- README → Task 6. ✅

**Placeholder scan:** No TBD/TODO; every code step is complete. ✅

**Type/name consistency:** `patch_nag`, `manage_repos`, `_disable_deb822`, `_disable_list`, `main`, env overrides `NAGFILE`/`MARKER`/`SOURCES_DIR`/`RELEASE`/`PVE_NAG_BUSTER_SOURCE`, marker `/etc/default/pve-nag-buster` with `MANAGE_REPOS=1` — used identically across tasks and the harness. ✅
