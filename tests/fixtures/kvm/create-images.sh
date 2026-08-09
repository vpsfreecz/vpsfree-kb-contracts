#!/usr/bin/env bash
set -euo pipefail

image_dir=${IMAGE_DIR:-/var/lib/libvirt/images}
image_size=${IMAGE_SIZE:-1G}

install -d -m 0755 "$image_dir"
truncate -s "$image_size" "$image_dir/guest.raw"
qemu-img create -q -f qcow2 "$image_dir/guest.qcow2" "$image_size"

qemu-img info --output=json "$image_dir/guest.raw"
qemu-img info --output=json "$image_dir/guest.qcow2"
du -h "$image_dir/guest.raw" "$image_dir/guest.qcow2"
