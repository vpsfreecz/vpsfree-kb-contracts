#!/usr/bin/env bash
set -eu

dnf install -y firewalld
systemctl enable --now firewalld
firewall-cmd --set-default-zone=public
firewall-cmd --permanent --zone=public --add-service=ssh
firewall-cmd --permanent --zone=public --add-service=http
firewall-cmd --permanent --zone=public --add-service=https
firewall-cmd --reload
firewall-cmd --get-active-zones
firewall-cmd --zone=public --list-all
