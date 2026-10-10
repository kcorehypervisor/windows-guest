#!/usr/bin/env bash
# Static checks for CI. Does not download Windows or virtio-win and does not start QEMU.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

shellcheck build.sh boot-ch.sh build-win10.sh boot-win10.sh scripts/check.sh

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# shellcheck disable=SC2016 # envsubst must see the placeholders, not expanded values
subst='${IMAGE_NAME} ${ADMIN_PASSWORD} ${COMPUTER_NAME} ${VIRTIO_OS} ${PRODUCT_KEY_XML}'
IMAGE_NAME="Windows Server 2022 SERVERSTANDARD" \
  ADMIN_PASSWORD="TestPassword1" \
  COMPUTER_NAME="KCORE-WIN" \
  VIRTIO_OS="2k22" \
  PRODUCT_KEY_XML="" \
  envsubst "$subst" \
  <seed/autounattend.xml >"$tmp"
xmllint --noout "$tmp"
grep -q 'Windows Server 2022 SERVERSTANDARD' "$tmp"
grep -q 'TestPassword1' "$tmp"
grep -q 'KCORE-WIN' "$tmp"
grep -q 'viostor\\2k22\\amd64' "$tmp"
grep -q 'post-install.ps1' "$tmp"
# shellcheck disable=SC2016
grep -q '\$p' "$tmp"

IMAGE_NAME="Windows 10 Pro" \
  ADMIN_PASSWORD="TestPassword1" \
  COMPUTER_NAME="KCORE-WIN10" \
  VIRTIO_OS="w10" \
  PRODUCT_KEY_XML='<ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>OnError</WillShowUI></ProductKey>' \
  envsubst "$subst" \
  <seed/autounattend.xml >"$tmp"
xmllint --noout "$tmp"
grep -q 'Windows 10 Pro' "$tmp"
grep -q 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' "$tmp"
grep -q 'KCORE-WIN10' "$tmp"
grep -q 'viostor\\w10\\amd64' "$tmp"
grep -q 'server2022' build.sh
grep -q 'win10' build.sh
grep -q 'WINDOWS_PROFILE=win10' build-win10.sh

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
