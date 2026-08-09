#!/usr/bin/env bash
set -euo pipefail

test -c /dev/kvm
test -r /dev/kvm
test -w /dev/kvm
test -c /dev/net/tun

printf 'KVM and TUN/TAP devices are available.\n'
