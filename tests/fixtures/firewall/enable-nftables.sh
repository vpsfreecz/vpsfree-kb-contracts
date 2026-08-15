#!/usr/bin/env bash
set -eu

apt update
DEBIAN_FRONTEND=noninteractive apt install -y nftables
nft -c -f /etc/nftables.conf
systemctl enable --now nftables
nft list ruleset
