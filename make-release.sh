#!/bin/sh
# Re-pack install.sh's embedded offline copy from the current pve-nag-buster.sh.
# Portable (macOS + Debian): requires xz and base64 on PATH. No `sed -i` (GNU-only).
set -e

start="$(grep -n "<< 'YEET'" install.sh | cut -d: -f1)"
end="$(grep -n '^YEET$' install.sh | cut -d: -f1)"
[ -n "$start" ] && [ -n "$end" ] || { echo "make-release: YEET markers not found in install.sh" >&2; exit 1; }

{
  head -n"$start" install.sh
  xz -z -9 -c pve-nag-buster.sh | base64
  tail -n+"$end" install.sh
} > install.sh.new
mv install.sh.new install.sh
echo "Re-packed install.sh offline blob from pve-nag-buster.sh"
