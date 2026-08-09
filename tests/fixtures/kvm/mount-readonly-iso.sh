#!/usr/bin/env bash
set -euo pipefail

: "${NFS_SERVER:?set NFS_SERVER to the NAS server address}"
: "${NFS_EXPORT:?set NFS_EXPORT to the exported dataset path}"

mountpoint=${ISO_MOUNTPOINT:-/mnt/installer-iso}
install -d -m 0755 "$mountpoint"
mount -t nfs -o ro,vers=3,nolock \
  "${NFS_SERVER}:${NFS_EXPORT}" "$mountpoint"

findmnt --noheadings --output FSTYPE,OPTIONS --target "$mountpoint"
