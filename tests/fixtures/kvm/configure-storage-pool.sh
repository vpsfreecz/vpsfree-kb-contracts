#!/usr/bin/env bash
set -euo pipefail

virsh --connect qemu:///system pool-define-as \
  vm-images dir --target /srv/libvirt/images
virsh --connect qemu:///system pool-start vm-images
virsh --connect qemu:///system pool-autostart vm-images
virsh --connect qemu:///system pool-info vm-images
