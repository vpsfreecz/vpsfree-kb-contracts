#!/usr/bin/env bash
set -eu

apt update
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw show added
grep -Fx 'IPV6=yes' /etc/default/ufw
ufw --force enable
ufw status verbose
