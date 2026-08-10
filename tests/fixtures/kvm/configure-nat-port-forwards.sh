#!/usr/bin/env bash
set -euo pipefail

: "${PUBLIC_IPV4:?set PUBLIC_IPV4 to the VPS public IPv4 address}"
: "${PUBLIC_IPV6:?set PUBLIC_IPV6 to a public IPv6 address of the VPS}"

guest_ipv4=${GUEST_IPV4:-192.168.124.10}
guest_ipv6=${GUEST_IPV6:-fd5f:6d2e:9c4a:124::10}
host_ipv4=${HOST_IPV4:-192.168.124.1}
host_ipv6=${HOST_IPV6:-fd5f:6d2e:9c4a:124::1}
connection=qemu:///system
network=dualstack-nat
hook=/etc/libvirt/hooks/network.d/50-port-forwards
config=/etc/libvirt/port-forwards.conf
xml=$(mktemp)
trap 'rm -f "$xml"' EXIT

network_uuid=$(virsh --connect "$connection" net-uuid "$network" 2>/dev/null || :)
uuid_element=
if [[ -n $network_uuid ]]; then
  uuid_element="  <uuid>$network_uuid</uuid>"
fi
cat >"$xml" <<EOF
<network>
  <name>$network</name>
$uuid_element
  <forward mode='nat'>
    <nat ipv6='yes'/>
  </forward>
  <bridge name='virbr-nat' stp='on' delay='0'/>
  <ip address='$host_ipv4' prefix='24'>
    <dhcp>
      <range start='192.168.124.100' end='192.168.124.254'/>
    </dhcp>
  </ip>
  <ip family='ipv6' address='$host_ipv6' prefix='64'/>
</network>
EOF

if virsh --connect "$connection" net-list --name \
  | grep -Fx "$network" >/dev/null; then
  printf '%s is active. Shut down its attached domains, run ' "$network" >&2
  printf 'virsh net-destroy %s, then rerun this script.\n' "$network" >&2
  exit 1
fi

install -d -m 0755 /etc/libvirt/hooks/network.d
install -d -m 0755 /etc/libvirt
cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
network=${1-}
action=${2-}
config=/etc/libvirt/port-forwards.conf
nat_chain=VPSFREE_KVM_DNAT
filter_chain=VPSFREE_KVM_FWD

[[ $network == dualstack-nat ]] || exit 0
exec 9>/run/lock/vpsfree-kvm-port-forwards.lock
flock 9

delete_jumps() {
  local tool
  for tool in iptables ip6tables; do
    while "$tool" -w -t nat -C PREROUTING -j "$nat_chain" 2>/dev/null; do
      "$tool" -w -t nat -D PREROUTING -j "$nat_chain"
    done
    while "$tool" -w -t filter -C FORWARD -j "$filter_chain" 2>/dev/null; do
      "$tool" -w -t filter -D FORWARD -j "$filter_chain"
    done
  done
}

delete_chains() {
  local tool
  for tool in iptables ip6tables; do
    if "$tool" -w -t nat -S "$nat_chain" >/dev/null 2>&1; then
      "$tool" -w -t nat -F "$nat_chain"
      "$tool" -w -t nat -X "$nat_chain"
    fi
    if "$tool" -w -t filter -S "$filter_chain" >/dev/null 2>&1; then
      "$tool" -w -t filter -F "$filter_chain"
      "$tool" -w -t filter -X "$filter_chain"
    fi
  done
}

cleanup() {
  delete_jumps
  delete_chains
}

valid_ip_address() {
  local family=$1 address=$2

  perl -MSocket=AF_INET,AF_INET6,inet_pton -e '
    my ($family, $address) = @ARGV;
    my $af = $family eq "ipv4" ? AF_INET : AF_INET6;
    exit(defined(inet_pton($af, $address)) ? 0 : 1);
  ' "$family" "$address"
}

if [[ $action == stopped ]]; then
  cleanup
  exit 0
fi
[[ $action == started || $action == reconnect ]] || exit 0

entries=()
while read -r family protocol public_ip public_port guest_ip guest_port extra \
    || [[ -n ${family:-} ]]; do
  [[ -n ${family:-} && $family != \#* ]] || continue
  [[ $family == ipv4 || $family == ipv6 ]] || {
    printf 'Invalid address family in %s: %s\n' "$config" "$family" >&2
    exit 1
  }
  [[ $protocol == tcp || $protocol == udp ]] || {
    printf 'Invalid protocol in %s: %s\n' "$config" "$protocol" >&2
    exit 1
  }
  for address in "$public_ip" "$guest_ip"; do
    valid_ip_address "$family" "$address" || {
      printf 'Invalid %s address in %s: %s\n' \
        "$family" "$config" "$address" >&2
      exit 1
    }
  done
  [[ $public_port =~ ^[0-9]{1,5}$ && $guest_port =~ ^[0-9]{1,5}$ ]] || {
    printf 'Invalid port in %s\n' "$config" >&2
    exit 1
  }
  public_port=$((10#$public_port))
  guest_port=$((10#$guest_port))
  ((public_port >= 1 && public_port <= 65535)) || exit 1
  ((guest_port >= 1 && guest_port <= 65535)) || exit 1
  [[ -z ${extra:-} ]] || {
    printf 'Too many fields in %s\n' "$config" >&2
    exit 1
  }
  entries+=("$family|$protocol|$public_ip|$public_port|$guest_ip|$guest_port")
done <"$config"

cleanup
for tool in iptables ip6tables; do
  "$tool" -w -t nat -N "$nat_chain"
  "$tool" -w -t filter -N "$filter_chain"
done
for entry in "${entries[@]}"; do
  IFS='|' read -r family protocol public_ip public_port guest_ip guest_port \
    <<<"$entry"
  tool=iptables
  destination="$guest_ip:$guest_port"
  if [[ $family == ipv6 ]]; then
    tool=ip6tables
    destination="[$guest_ip]:$guest_port"
  fi
  "$tool" -w -t nat -A "$nat_chain" -p "$protocol" -d "$public_ip" \
    --dport "$public_port" -j DNAT --to-destination "$destination"
  "$tool" -w -t filter -A "$filter_chain" -p "$protocol" -d "$guest_ip" \
    --dport "$guest_port" -j ACCEPT
done
for tool in iptables ip6tables; do
  "$tool" -w -t nat -I PREROUTING 1 -j "$nat_chain"
  "$tool" -w -t filter -I FORWARD 1 -j "$filter_chain"
done
HOOK
chmod 0755 "$hook"

cat >"$config" <<EOF
# FAMILY PROTOCOL PUBLIC_IP PUBLIC_PORT GUEST_IP GUEST_PORT
ipv4 tcp $PUBLIC_IPV4 80 $guest_ipv4 80
ipv4 tcp $PUBLIC_IPV4 2222 $guest_ipv4 22
ipv6 tcp $PUBLIC_IPV6 80 $guest_ipv6 80
ipv6 tcp $PUBLIC_IPV6 2222 $guest_ipv6 22
EOF

virsh --connect "$connection" net-define "$xml"
virsh --connect "$connection" net-autostart "$network"
systemctl restart libvirtd.service
if ! virsh --connect "$connection" net-list --name \
  | grep -Fx "$network" >/dev/null; then
  virsh --connect "$connection" net-start "$network"
fi
"$hook" "$network" started begin -
virsh --connect "$connection" net-dumpxml "$network"
