#!/usr/bin/env bash
# Build a Windows raw disk that can boot on Cloud Hypervisor.
# WINDOWS_PROFILE=server2022 (default) or win10.
# The Windows ISO is supplied by the operator and is never downloaded by this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${ROOT}/build"
WIN_ISO="${WIN_ISO:-}"
PROFILE="${WINDOWS_PROFILE:-server2022}"
case "$PROFILE" in
  server2022)
    : "${WINDOWS_IMAGE:=Windows Server 2022 SERVERSTANDARD}"
    : "${VIRTIO_OS:=2k22}"
    : "${WINDOWS_COMPUTER_NAME:=KCORE-WIN}"
    : "${DISK:=${BUILD}/windows-server-2022.raw}"
    ;;
  win10)
    : "${WINDOWS_IMAGE:=Windows 10 Pro}"
    : "${VIRTIO_OS:=w10}"
    : "${WINDOWS_COMPUTER_NAME:=KCORE-WIN10}"
    : "${DISK:=${BUILD}/windows-10.raw}"
    # Public setup key. It installs Pro and does not activate Windows.
    : "${WINDOWS_PRODUCT_KEY:=VK7JG-NPHTM-C97JM-9MPGT-3V66T}"
    ;;
  *)
    echo "error: WINDOWS_PROFILE must be server2022 or win10" >&2
    exit 1
    ;;
esac
IMAGE_NAME="$WINDOWS_IMAGE"
COMPUTER_NAME="$WINDOWS_COMPUTER_NAME"
DISK_SIZE_GB="${DISK_SIZE_GB:-40}"
MEMORY_MB="${MEMORY_MB:-4096}"
CPUS="${CPUS:-2}"

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
  local stamp dest name listed
  stamp="$(iso_stamp)"
  mkdir -p "$BUILD"
  if [[ -f "${BUILD}/iso.stamp" && -f "${BUILD}/install.media" ]] && [[ "$(cat "${BUILD}/iso.stamp")" == "$stamp" ]]; then
    return
  fi
  dest="${BUILD}/install.media"
  rm -f "$dest"
  # Evaluation ISOs keep the payload in UDF. xorriso only sees the ISO9660
  # stub, so 7z is what can see sources/install.wim.
  listed="$(7z l -ba "$WIN_ISO")"
  for name in install.wim install.esd; do
    # grep -q in a pipeline trips pipefail when it exits early. A here-string does not.
    if grep -a -F -q "sources/${name}" <<<"$listed"; then
      echo "extracting sources/${name} to list editions" >&2
      rm -rf "${BUILD}/wim-extract"
      mkdir -p "${BUILD}/wim-extract"
      7z x -bd -y -o"${BUILD}/wim-extract" "$WIN_ISO" "sources/${name}" >&2
      mv "${BUILD}/wim-extract/sources/${name}" "$dest"
      rm -rf "${BUILD}/wim-extract"
      printf '%s\n' "$stamp" >"${BUILD}/iso.stamp"
      return
    fi
  done
  die "ISO has neither sources/install.wim nor sources/install.esd"
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
  mkdir -p "$root/viostor/${VIRTIO_OS}/amd64" "$root/NetKVM/${VIRTIO_OS}/amd64"
  # shellcheck disable=SC2016 # envsubst must see the placeholders, not expanded values
  local subst='${IMAGE_NAME} ${ADMIN_PASSWORD} ${COMPUTER_NAME} ${VIRTIO_OS} ${PRODUCT_KEY_XML}'
  local product_key_xml=""
  if [[ -n "${WINDOWS_PRODUCT_KEY:-}" ]]; then
    [[ "$WINDOWS_PRODUCT_KEY" =~ ^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$ ]] || die "WINDOWS_PRODUCT_KEY must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
    product_key_xml="<ProductKey><Key>${WINDOWS_PRODUCT_KEY}</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
  fi
  IMAGE_NAME="$IMAGE_NAME" ADMIN_PASSWORD="$ADMIN_PASSWORD" COMPUTER_NAME="$COMPUTER_NAME" VIRTIO_OS="$VIRTIO_OS" PRODUCT_KEY_XML="$product_key_xml" \
    envsubst "$subst" <"${ROOT}/seed/autounattend.xml" >"$root/autounattend.xml"
  IMAGE_NAME="$IMAGE_NAME" ADMIN_PASSWORD="$ADMIN_PASSWORD" COMPUTER_NAME="$COMPUTER_NAME" VIRTIO_OS="$VIRTIO_OS" \
    envsubst "$subst" <"${ROOT}/seed/load-viostor.cmd" >"$root/load-viostor.cmd"
  IMAGE_NAME="$IMAGE_NAME" ADMIN_PASSWORD="$ADMIN_PASSWORD" COMPUTER_NAME="$COMPUTER_NAME" VIRTIO_OS="$VIRTIO_OS" \
    envsubst "$subst" <"${ROOT}/seed/post-install.ps1" >"$root/post-install.ps1"
  cp "${ROOT}/seed/kcore-windows-seed.txt" "$root/"
  chmod 755 "$root/load-viostor.cmd"
  xorriso -osirrox on -indev "$VIRTIO_ISO" -extract "/viostor/${VIRTIO_OS}/amd64" "$root/viostor/${VIRTIO_OS}/amd64"
  xorriso -osirrox on -indev "$VIRTIO_ISO" -extract "/NetKVM/${VIRTIO_OS}/amd64" "$root/NetKVM/${VIRTIO_OS}/amd64"
  [[ -f "$root/viostor/${VIRTIO_OS}/amd64/viostor.inf" ]] || die "viostor.inf missing from virtio ISO (expected /viostor/${VIRTIO_OS}/amd64)"
  [[ -f "$root/NetKVM/${VIRTIO_OS}/amd64/netkvm.inf" ]] || die "netkvm.inf missing from virtio ISO (expected /NetKVM/${VIRTIO_OS}/amd64)"
  rm -f "${BUILD}/seed.iso"
  xorriso -as mkisofs -o "${BUILD}/seed.iso" -V KCORESEED -J -R "$root"
}

poke_boot_key() {
  local sock="$1" i
  # The Windows DVD bootloader waits a few seconds for a key. Send Enter
  # early and often so OVMF does not report that wait as a boot timeout.
  sleep 3
  for ((i = 0; i < 25; i++)); do
    python3 - "$sock" <<'PY' || true
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
    s.sendall(b"sendkey ret\n")
finally:
    s.close()
PY
    sleep 2
  done
}

# The "Press any key to boot from CD" prompt is on the EFI serial console.
# A serial file cannot receive that key, so the console is a socket.
log_serial() {
  local sock="$1"
  python3 - "$sock" "${BUILD}/serial.log" <<'PY' || true
import socket, sys, time
sock_path, log_path = sys.argv[1], sys.argv[2]
deadline = time.time() + 90
s = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.2)
        s = None
if s is None:
    sys.exit(0)
sent_until = time.time() + 40
with open(log_path, "wb", buffering=0) as log:
    while True:
        if time.time() < sent_until:
            try:
                s.sendall(b"\r")
            except OSError:
                break
        try:
            data = s.recv(4096)
        except TimeoutError:
            continue
        except OSError:
            break
        if not data:
            break
        log.write(data)
PY
}

run_qemu() {
  local poker sock="${BUILD}/monitor.sock"
  echo "VNC: 127.0.0.1:5900"
  echo "installer SSH forward (after OpenSSH is installed): ssh -p 2222 Administrator@127.0.0.1"
  echo "admin password: ${BUILD}/admin-password.txt"
  rm -f "$sock" "${BUILD}/serial.sock" "${BUILD}/serial.log"
  poke_boot_key "$sock" &
  poker=$!
  log_serial "${BUILD}/serial.sock" &
  logger=$!
  trap 'kill "$poker" "$logger" 2>/dev/null || true' RETURN
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
    -monitor "unix:${sock},server,nowait" \
    -serial "unix:${BUILD}/serial.sock,server=on,wait=off"
}

if [[ "${1:-}" == "--list-images" ]]; then
  [[ -n "$WIN_ISO" && -f "$WIN_ISO" ]] || die "set WIN_ISO to a Windows ISO"
  need 7z
  need wiminfo
  list_images
  exit 0
fi

[[ "$(uname -m)" == "x86_64" ]] || die "this recipe targets x86_64"
[[ -r /dev/kvm ]] || die "/dev/kvm is not readable"
[[ -n "${OVMF_CODE:-}" && -f "$OVMF_CODE" ]] || die "OVMF_CODE is unset or missing (run: nix develop -c ./build.sh)"
[[ -n "$WIN_ISO" && -f "$WIN_ISO" ]] || die "set WIN_ISO to a Windows ISO you are licensed to use"
[[ "$VIRTIO_OS" =~ ^[A-Za-z0-9.]{1,16}$ ]] || die "VIRTIO_OS must be a virtio-win directory name such as 2k22 or w10"
[[ "$COMPUTER_NAME" =~ ^[A-Za-z0-9-]{1,15}$ ]] || die "WINDOWS_COMPUTER_NAME must be 1-15 letters, digits, or hyphens"
[[ "$IMAGE_NAME" != *'&'* && "$IMAGE_NAME" != *'<'* && "$IMAGE_NAME" != *'>'* ]] || die "WINDOWS_IMAGE contains XML metacharacters"

for cmd in qemu-system-x86_64 qemu-img xorriso 7z wiminfo curl sha256sum envsubst python3; do
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
