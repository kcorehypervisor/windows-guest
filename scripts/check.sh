#!/usr/bin/env bash
# Static checks for CI. Does not download Windows or virtio-win and does not start QEMU.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

shellcheck build.sh boot-ch.sh scripts/check.sh

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# shellcheck disable=SC2016 # envsubst must see the placeholders, not expanded values
IMAGE_NAME="Windows Server 2022 SERVERSTANDARD" \
  ADMIN_PASSWORD="TestPassword1" \
  COMPUTER_NAME="KCORE-WIN" \
  envsubst '${IMAGE_NAME} ${ADMIN_PASSWORD} ${COMPUTER_NAME}' \
  <seed/autounattend.xml >"$tmp"
xmllint --noout "$tmp"
grep -q 'Windows Server 2022 SERVERSTANDARD' "$tmp"
grep -q 'TestPassword1' "$tmp"
grep -q 'KCORE-WIN' "$tmp"
grep -q 'post-install.ps1' "$tmp"
# shellcheck disable=SC2016
grep -q '\$p' "$tmp"

grep -q 'virtio-win-0.1.240-1/virtio-win.iso' build.sh
grep -q 'ebd48258668f7f78e026ed276c28a9d19d83e020ffa080ad69910dc86bbcbcc6' build.sh
grep -q 'kvm_hyperv=on' boot-ch.sh

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git ls-files | grep -E '\.(iso|raw|wim|esd)$'; then
    echo "error: Windows media or a built disk is tracked" >&2
    exit 1
  fi
fi

echo "recipe checks passed"
