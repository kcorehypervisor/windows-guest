#!/usr/bin/env bash
# Boot a disk built by build.sh under Cloud Hypervisor.
# The serial line is the terminal. SAC (EMS) comes up on COM1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK="${DISK:-${ROOT}/build/windows-server-2022.raw}"
FW="${CLOUDHV_FW:-}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-4G}"
SOCK="${ROOT}/build/ch.sock"

[[ -n "$FW" && -f "$FW" ]] || {
  echo "error: CLOUDHV_FW is unset or missing (run: nix develop -c ./boot-ch.sh)" >&2
  exit 1
}
[[ -f "$DISK" ]] || {
  echo "error: missing disk ${DISK}" >&2
  exit 1
}
[[ -r /dev/kvm ]] || {
  echo "error: /dev/kvm is not readable" >&2
  exit 1
}
command -v cloud-hypervisor >/dev/null 2>&1 || {
  echo "error: cloud-hypervisor is not on PATH" >&2
  exit 1
}

mkdir -p "${ROOT}/build"
rm -f "$SOCK"
echo "firmware: ${FW}"
echo "disk: ${DISK}"
echo "serial is this terminal; SAC prompt is 'SAC>'"
exec cloud-hypervisor \
  --api-socket "$SOCK" \
  --cpus "boot=${CPUS},kvm_hyperv=on" \
  --memory "size=${MEMORY}" \
  --firmware "$FW" \
  --disk "path=${DISK},image_type=raw" \
  --serial tty \
  --console off
