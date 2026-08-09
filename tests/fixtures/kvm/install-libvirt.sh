#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes \
  libvirt-clients \
  libvirt-daemon-system \
  qemu-system-x86 \
  qemu-utils \
  virtinst

systemctl enable --now libvirtd.service
virsh --connect qemu:///system version
