# Windows Server guest image for Cloud Hypervisor

Unattended QEMU recipe that installs Windows Server 2022 or Windows 10 onto a raw disk with virtio block and virtio-net drivers and OpenSSH Server. Server also enables the serial console (SAC). The resulting disk boots on [Cloud Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor).

This repository holds the recipe only. It does not contain a Windows ISO, a product key, or a built disk image. Publishing any of those would redistribute Microsoft Windows. Build the image on a machine you control, from installation media you are licensed to use, and keep the disk private.

## Why the driver pin exists

Cloud Hypervisor's Windows support needs Hyper-V enlightenments (`kvm_hyperv=on`) and virtio drivers baked into the image. Newer virtio-win builds misbehave on current Cloud Hypervisor:

- virtio-win 0.1.271 and later fails to start NetKVM because Cloud Hypervisor rejects most virtio-net control-queue commands.
- virtio-win 0.1.285 and later can bugcheck in `viostor` when the disk advertises discard, which qcow2 does.

This recipe pins [virtio-win 0.1.240](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.240-1/) and writes a raw disk. Fedora redistributes that ISO. The script checks its SHA256 before use.

Windows 11 uses this same recipe once the image exists. Setup refuses to start without a TPM 2.0 and Secure Boot, and Cloud Hypervisor on kcore presents neither. A lab image skips those two checks in the answer file, then boots with the same `kvm_hyperv=on` command line as Server. That is not a Microsoft-supported configuration. Set `WINDOWS_IMAGE` to an edition name printed by `--list-images` and `VIRTIO_OS=w11`. The Server and Windows 10 builds already select `2k22` and `w10`.

## Prerequisites

- x86_64 Linux host with `/dev/kvm`
- Nix, so `nix develop` can provide QEMU, OVMF, xorriso, wimlib, and Cloud Hypervisor
- A Windows Server 2022 ISO from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022), or other Server 2022 media you are licensed to install
- Enough free space for a sparse 40G raw disk plus the extracted `install.wim` (the file is sparse until Windows writes it; the WIM extract is several gigabytes)

## Build

Server 2022:

```bash
nix develop -c ./build.sh --list-images
# set WIN_ISO, then:
nix develop -c ./build.sh
```

Windows 10 uses the same installer and the `w10` virtio drivers:

```bash
nix develop -c ./build-win10.sh --list-images
# set WIN_ISO to Windows 10 media, then:
nix develop -c ./build-win10.sh
```

`WIN_ISO` is the path to your ISO. The Server default edition is `Windows Server 2022 SERVERSTANDARD`. The Windows 10 default is `Windows 10 Pro`, with Microsoft's public Pro setup key so the consumer ISO does not stop and ask for one. That key does not activate Windows. Override the edition with `WINDOWS_IMAGE` using a name printed by `--list-images`, and set `WINDOWS_PRODUCT_KEY` when that edition needs a different key.

The build:

1. Downloads virtio-win 0.1.240 and checks the pinned SHA256.
2. Builds a second CD with `autounattend.xml`, `viostor`, and `NetKVM`.
3. Installs Windows under QEMU onto a virtio disk, using OVMF. The first boot is the DVD; later boots are the disk.
4. Enables SAC on COM1, installs the virtio NIC driver, installs OpenSSH, and shuts down.

Watch the installer on VNC at `127.0.0.1:5900` if it stops. A generated Administrator password is written to `build/admin-password.txt` (mode 0600). Set `WINDOWS_ADMIN_PASSWORD` to choose one (8–64 letters and digits).

Useful overrides: `DISK_SIZE_GB` (default 40), `MEMORY_MB` (default 4096), `CPUS` (default 2), `WINDOWS_COMPUTER_NAME` (default `KCORE-WIN` or `KCORE-WIN10`), `FORCE=1` to replace an existing disk.

The Server disk is `build/windows-server-2022.raw`. The Windows 10 disk is `build/windows-10.raw`. Windows 10 has no SAC prompt; after the build, SSH to the guest as `Administrator`.

## Boot on Cloud Hypervisor

```bash
nix develop -c ./boot-ch.sh
nix develop -c ./boot-win10.sh
```

This is the test that matters. It starts Cloud Hypervisor with `kvm_hyperv=on`, the Cloud Hypervisor OVMF firmware, and the raw disk. The terminal is the serial port. After boot you should see a `SAC>` prompt. `cmd` then `ch -si 1` opens a command channel, as described in the [Cloud Hypervisor Windows guide](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/windows.md).

Log in as `Administrator` with the password in `build/admin-password.txt`.

## Use the disk with kcore

kcore boots the disk with the same VM path as a Linux guest. The node image starts Cloud Hypervisor with `kvm_hyperv=on` for every VM. A cloud-init seed is still attached; Windows ignores it. Log in as `Administrator` from this image, not as the cloud-init user. `boot-ch.sh` is the local check before upload.

When you only need the file on a node:

```bash
kctl --node <node:9091> node upload-image \
  -f build/windows-server-2022.raw \
  --format raw \
  --name windows-server-2022.raw
```

The command prints the node-local path. Do not publish that image.

## What CI runs

GitHub Actions runs `scripts/check.sh`: shellcheck, a substituted `autounattend.xml` well-formedness check, and a guard that the Windows ISO and the built disk are not tracked. CI does not install Windows. KVM and the evaluation ISO stay on the lab machine.
