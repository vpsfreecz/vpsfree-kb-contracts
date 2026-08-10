#!/usr/bin/env bash
set -euo pipefail

: "${DOMAIN:?set DOMAIN to the libvirt domain name}"
: "${PUBLIC_IPV4:?set PUBLIC_IPV4 to the VPS public IPv4 address}"

guest_ipv4=${GUEST_IPV4:-192.168.122.10}
connection=qemu:///system
hook=/etc/libvirt/hooks/network.d/50-port-forwards
config=/etc/libvirt/port-forwards.conf

export LC_ALL=C
virsh --connect "$connection" net-autostart default
if ! virsh --connect "$connection" net-info default | grep -Eq '^Active:[[:space:]]+yes$'; then
  virsh --connect "$connection" net-start default
fi

guest_mac=$(virsh --connect "$connection" domiflist "$DOMAIN" \
  | awk '$3 == "default" { print $5; exit }')
if [[ ! $guest_mac =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
  printf 'Unable to find the default-network MAC for %s\n' "$DOMAIN" >&2
  exit 1
fi

reservation="<host mac='$guest_mac' name='$DOMAIN' ip='$guest_ipv4'/>"
if virsh --connect "$connection" net-dumpxml default \
  | grep -Fq "mac='$guest_mac'"; then
  virsh --connect "$connection" net-update default modify ip-dhcp-host \
    "$reservation" --live --config
else
  virsh --connect "$connection" net-update default add-last ip-dhcp-host \
    "$reservation" --live --config
fi

install -d -m 0755 /etc/libvirt/hooks/network.d
install -d -m 0755 /etc/libvirt
touch "$hook"
chmod 0755 "$hook"
cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
network=${1-}
action=${2-}
config=/etc/libvirt/port-forwards.conf
nat_chain=VPSFREE_KVM_DNAT
filter_chain=VPSFREE_KVM_FWD

[[ $network == default ]] || exit 0
exec 9>/run/lock/vpsfree-kvm-port-forwards.lock
flock 9

delete_jumps() {
  while iptables -w -t nat -C PREROUTING -j "$nat_chain" 2>/dev/null; do
    iptables -w -t nat -D PREROUTING -j "$nat_chain"
  done
  while iptables -w -t filter -C FORWARD -j "$filter_chain" 2>/dev/null; do
    iptables -w -t filter -D FORWARD -j "$filter_chain"
  done
}

delete_chains() {
  if iptables -w -t nat -S "$nat_chain" >/dev/null 2>&1; then
    iptables -w -t nat -F "$nat_chain"
    iptables -w -t nat -X "$nat_chain"
  fi
  if iptables -w -t filter -S "$filter_chain" >/dev/null 2>&1; then
    iptables -w -t filter -F "$filter_chain"
    iptables -w -t filter -X "$filter_chain"
  fi
}

cleanup() {
  delete_jumps
  delete_chains
}

if [[ $action == stopped ]]; then
  cleanup
  exit 0
fi
[[ $action == started || $action == reconnect ]] || exit 0

valid_ipv4() {
  local octet
  local -a octets
  IFS=. read -r -a octets <<<"$1"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
}

entries=()
while read -r protocol public_ip public_port guest_ip guest_port extra; do
  [[ -n ${protocol:-} && $protocol != \#* ]] || continue
  [[ $protocol == tcp || $protocol == udp ]] || {
    printf 'Invalid protocol in %s: %s\n' "$config" "$protocol" >&2
    exit 1
  }
  valid_ipv4 "$public_ip" && valid_ipv4 "$guest_ip" || {
    printf 'Invalid IPv4 address in %s\n' "$config" >&2
    exit 1
  }
  [[ $public_port =~ ^[0-9]+$ && $guest_port =~ ^[0-9]+$ ]] || {
    printf 'Invalid port in %s\n' "$config" >&2
    exit 1
  }
  ((public_port >= 1 && public_port <= 65535)) || exit 1
  ((guest_port >= 1 && guest_port <= 65535)) || exit 1
  [[ -z ${extra:-} ]] || {
    printf 'Too many fields in %s\n' "$config" >&2
    exit 1
  }
  entries+=("$protocol|$public_ip|$public_port|$guest_ip|$guest_port")
done <"$config"

cleanup
iptables -w -t nat -N "$nat_chain"
iptables -w -t filter -N "$filter_chain"
for entry in "${entries[@]}"; do
  IFS='|' read -r protocol public_ip public_port guest_ip guest_port <<<"$entry"
  iptables -w -t nat -A "$nat_chain" -p "$protocol" -d "$public_ip" \
    --dport "$public_port" -j DNAT --to-destination "$guest_ip:$guest_port"
  iptables -w -t filter -A "$filter_chain" -p "$protocol" -d "$guest_ip" \
    --dport "$guest_port" -j ACCEPT
done
iptables -w -t nat -I PREROUTING 1 -j "$nat_chain"
iptables -w -t filter -I FORWARD 1 -j "$filter_chain"
HOOK

cat >"$config" <<EOF
# PROTOCOL PUBLIC_IP PUBLIC_PORT GUEST_IP GUEST_PORT
tcp $PUBLIC_IPV4 80 $guest_ipv4 80
tcp $PUBLIC_IPV4 2222 $guest_ipv4 22
udp $PUBLIC_IPV4 5353 $guest_ipv4 9000
EOF

systemctl restart libvirtd.service
"$hook" default started begin -
