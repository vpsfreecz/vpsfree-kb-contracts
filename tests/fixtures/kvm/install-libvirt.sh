#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes \
  iptables \
  libvirt-clients \
  libvirt-daemon-system \
  qemu-system-x86 \
  qemu-utils \
  virtinst

virsh --connect qemu:///system version
