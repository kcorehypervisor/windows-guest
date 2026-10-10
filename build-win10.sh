#!/usr/bin/env bash
# Windows 10 build. Same installer as build.sh, with the w10 virtio drivers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WINDOWS_PROFILE=win10
exec "${ROOT}/build.sh" "$@"
