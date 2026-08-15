#!/usr/bin/env bash
set -eu

apt update
DEBIAN_FRONTEND=noninteractive apt install -y iptables iptables-persistent

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
ip6tables -P INPUT ACCEPT
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT

iptables -F
iptables -X
ip6tables -F
ip6tables -X

iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -p tcp -m multiport --dports 22,80,443 -j ACCEPT

ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
ip6tables -A INPUT -p tcp -m multiport --dports 22,80,443 -j ACCEPT

iptables -P INPUT DROP
iptables -P FORWARD DROP
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP

netfilter-persistent save
iptables -L INPUT -n -v
ip6tables -L INPUT -n -v
