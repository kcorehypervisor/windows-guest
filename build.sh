#!/usr/bin/env bash
# Build a Windows Server 2022 raw disk that can boot on Cloud Hypervisor.
# The Windows ISO is supplied by the operator and is never downloaded by this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${ROOT}/build"
WIN_ISO="${WIN_ISO:-}"
IMAGE_NAME="${WINDOWS_IMAGE:-Windows Server 2022 SERVERSTANDARD}"
COMPUTER_NAME="${WINDOWS_COMPUTER_NAME:-KCORE-WIN}"
DISK_SIZE_GB="${DISK_SIZE_GB:-40}"
MEMORY_MB="${MEMORY_MB:-4096}"
CPUS="${CPUS:-2}"
DISK="${DISK:-${BUILD}/windows-server-2022.raw}"

VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.240-1/virtio-win.iso"
VIRTIO_SHA256="ebd48258668f7f78e026ed276c28a9d19d83e020ffa080ad69910dc86bbcbcc6"
VIRTIO_ISO="${BUILD}/virtio-win-0.1.240.iso"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing $1 (run: nix develop -c ./build.sh)"
}

iso_stamp() {
  stat -c '%s %Y' "$WIN_ISO"
}

extract_install_media() {
  local stamp dest name
  stamp="$(iso_stamp)"
  mkdir -p "$BUILD"
  if [[ -f "${BUILD}/iso.stamp" && -f "${BUILD}/install.media" ]] && [[ "$(cat "${BUILD}/iso.stamp")" == "$stamp" ]]; then
    return
  fi
  dest="${BUILD}/install.media"
  rm -f "$dest"
  for name in install.wim install.esd; do
    if xorriso -indev "$WIN_ISO" -find /sources -name "$name" 2>/dev/null | grep -q "/${name}$"; then
      echo "extracting /sources/${name} to list editions"
      xorriso -osirrox on -indev "$WIN_ISO" -extract "/sources/${name}" "$dest"
      printf '%s\n' "$stamp" >"${BUILD}/iso.stamp"
      return
    fi
  done
  die "ISO has neither /sources/install.wim nor /sources/install.esd"
}

list_images() {
  extract_install_media
  sed -n 's/^Name:[[:space:]]*//p' < <(wiminfo "${BUILD}/install.media")
}

require_image_name() {
  local names
  names="$(list_images)"
  echo "editions in ISO:"
  printf '%s\n' "$names" | sed 's/^/  /'
  if ! printf '%s\n' "$names" | grep -Fxq "$IMAGE_NAME"; then
    die "WINDOWS_IMAGE='${IMAGE_NAME}' is not in this ISO. Set WINDOWS_IMAGE to one of the names above."
  fi
}

write_password() {
  local pass="$1"
  umask 077
  printf '%s\n' "$pass" >"${BUILD}/admin-password.txt"
  chmod 600 "${BUILD}/admin-password.txt"
}

fetch_virtio() {
  mkdir -p "$BUILD"
  if [[ -f "$VIRTIO_ISO" ]] && echo "${VIRTIO_SHA256}  ${VIRTIO_ISO}" | sha256sum -c -; then
    return
  fi
  echo "downloading virtio-win 0.1.240"
  curl -fL --retry 3 --retry-delay 2 -o "${VIRTIO_ISO}.partial" "$VIRTIO_URL"
  mv "${VIRTIO_ISO}.partial" "$VIRTIO_ISO"
  echo "${VIRTIO_SHA256}  ${VIRTIO_ISO}" | sha256sum -c -
}

stage_seed() {
  local root="${BUILD}/seed-root"
  rm -rf "$root"
  mkdir -p "$root/viostor/2k22/amd64" "$root/NetKVM/2k22/amd64"
  cp "${ROOT}/seed/load-viostor.cmd" "${ROOT}/seed/post-install.ps1" "${ROOT}/seed/kcore-windows-seed.txt" "$root/"
  # shellcheck disable=SC2016 # envsubst must see the placeholders, not expanded values
  IMAGE_NAME="$IMAGE_NAME" ADMIN_PASSWORD="$ADMIN_PASSWORD" COMPUTER_NAME="$COMPUTER_NAME" \
    envsubst '${IMAGE_NAME} ${ADMIN_PASSWORD} ${COMPUTER_NAME}' \
    <"${ROOT}/seed/autounattend.xml" >"$root/autounattend.xml"
  xorriso -osirrox on -indev "$VIRTIO_ISO" -extract /viostor/2k22/amd64 "$root/viostor/2k22/amd64"
  xorriso -osirrox on -indev "$VIRTIO_ISO" -extract /NetKVM/2k22/amd64 "$root/NetKVM/2k22/amd64"
  [[ -f "$root/viostor/2k22/amd64/viostor.inf" ]] || die "viostor.inf missing from virtio ISO (expected /viostor/2k22/amd64)"
  [[ -f "$root/NetKVM/2k22/amd64/netkvm.inf" ]] || die "netkvm.inf missing from virtio ISO (expected /NetKVM/2k22/amd64)"
  rm -f "${BUILD}/seed.iso"
  xorriso -as mkisofs -o "${BUILD}/seed.iso" -V KCORESEED -J -R "$root"
}

run_qemu() {
  echo "VNC: 127.0.0.1:5900"
  echo "installer SSH forward (after OpenSSH is installed): ssh -p 2222 Administrator@127.0.0.1"
  echo "admin password: ${BUILD}/admin-password.txt"
  qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m "$MEMORY_MB" \
    -smp "$CPUS" \
    -bios "$OVMF_CODE" \
    -drive "if=none,id=root,file=${DISK},format=raw" \
    -device virtio-blk-pci,drive=root,disable-legacy=on,bootindex=1 \
    -device ahci,id=ahci \
    -drive "file=${WIN_ISO},if=none,id=winiso,media=cdrom,readonly=on" \
    -device ide-cd,drive=winiso,bus=ahci.0,bootindex=2 \
    -drive "file=${BUILD}/seed.iso,if=none,id=seediso,media=cdrom,readonly=on" \
    -device ide-cd,drive=seediso,bus=ahci.1 \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=n0,disable-legacy=on \
    -vga std \
    -display "vnc=127.0.0.1:0" \
    -serial "file:${BUILD}/serial.log"
}

if [[ "${1:-}" == "--list-images" ]]; then
  [[ -n "$WIN_ISO" && -f "$WIN_ISO" ]] || die "set WIN_ISO to a Windows Server 2022 ISO"
  need xorriso
  need wiminfo
  list_images
  exit 0
fi

[[ "$(uname -m)" == "x86_64" ]] || die "this recipe targets x86_64"
[[ -r /dev/kvm ]] || die "/dev/kvm is not readable"
[[ -n "${OVMF_CODE:-}" && -f "$OVMF_CODE" ]] || die "OVMF_CODE is unset or missing (run: nix develop -c ./build.sh)"
[[ -n "$WIN_ISO" && -f "$WIN_ISO" ]] || die "set WIN_ISO to a Windows Server 2022 ISO you are licensed to use"
[[ "$COMPUTER_NAME" =~ ^[A-Za-z0-9-]{1,15}$ ]] || die "WINDOWS_COMPUTER_NAME must be 1-15 letters, digits, or hyphens"
[[ "$IMAGE_NAME" != *'&'* && "$IMAGE_NAME" != *'<'* && "$IMAGE_NAME" != *'>'* ]] || die "WINDOWS_IMAGE contains XML metacharacters"

for cmd in qemu-system-x86_64 qemu-img xorriso wiminfo curl sha256sum envsubst; do
  need "$cmd"
done

if [[ -n "${WINDOWS_ADMIN_PASSWORD:-}" ]]; then
  ADMIN_PASSWORD="$WINDOWS_ADMIN_PASSWORD"
  [[ "$ADMIN_PASSWORD" =~ ^[A-Za-z0-9]{8,64}$ ]] || die "WINDOWS_ADMIN_PASSWORD must be 8-64 letters and digits"
else
  # tr|head trips pipefail when head closes the pipe.
  set +o pipefail
  ADMIN_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  set -o pipefail
  [[ ${#ADMIN_PASSWORD} -eq 20 ]] || die "failed to generate an Administrator password"
fi

mkdir -p "$BUILD"
write_password "$ADMIN_PASSWORD"
require_image_name
fetch_virtio
stage_seed

if [[ -e "$DISK" && "${FORCE:-}" != "1" ]]; then
  die "${DISK} already exists (set FORCE=1 to replace it)"
fi
rm -f "$DISK"
qemu-img create -f raw "$DISK" "${DISK_SIZE_GB}G"
run_qemu

echo "image: ${DISK}"
echo "password: ${BUILD}/admin-password.txt"
echo "next: nix develop -c ./boot-ch.sh"
