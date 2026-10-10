#!/usr/bin/env bash
# Boot the Windows 10 disk from build-win10.sh under Cloud Hypervisor.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DISK="${DISK:-${ROOT}/build/windows-10.raw}"
exec "${ROOT}/boot-ch.sh"
