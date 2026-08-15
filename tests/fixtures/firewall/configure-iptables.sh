#!/usr/bin/env bash
set -eu

# Install the command-line tools and boot-time persistence.
apt update
apt install -y iptables iptables-persistent

# Keep traffic allowed while replacing the current rules.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
ip6tables -P INPUT ACCEPT
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT

# Remove the current filter rules and user-defined chains.
iptables -F
iptables -X
ip6tables -F
ip6tables -X

# IPv4 input: drop invalid packets, keep established traffic, and open services.
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -p tcp -m multiport --dports 22,80,443 -j ACCEPT

# IPv6 input: apply the same policy and keep IPv6 control traffic working.
ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
ip6tables -A INPUT -p tcp -m multiport --dports 22,80,443 -j ACCEPT

# Drop other input and forwarded traffic; keep locally generated output allowed.
iptables -P INPUT DROP
iptables -P FORWARD DROP
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP

# Persist the rules and display the resulting input policy.
netfilter-persistent save
iptables -L INPUT -n -v
ip6tables -L INPUT -n -v
