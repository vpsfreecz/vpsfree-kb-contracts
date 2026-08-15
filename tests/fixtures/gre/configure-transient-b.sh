#!/usr/bin/env bash
set -eu

ip tunnel add gre1 mode gre \
  local 185.8.164.20 remote 185.8.164.10 ttl 255
ip address add 10.0.0.2/30 dev gre1
ip link set dev gre1 mtu 1476 up
