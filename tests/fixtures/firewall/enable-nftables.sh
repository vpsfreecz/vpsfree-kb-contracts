#!/usr/bin/env bash
set -eu

# Install nftables.
apt update
DEBIAN_FRONTEND=noninteractive apt install -y nftables

# Validate the complete configuration before applying it.
nft -c -f /etc/nftables.conf

# Load the configuration now and at boot, then display the result.
systemctl enable --now nftables
nft list ruleset
