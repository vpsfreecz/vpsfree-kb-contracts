#!/usr/bin/env bash
set -euo pipefail

: "${PUBLIC_IPV4:?set PUBLIC_IPV4 to the routed public IPv4 address}"
: "${IPV6_GATEWAY:?set IPV6_GATEWAY to the first address of the routed IPv6 /64}"

host_transit_ipv4=${HOST_TRANSIT_IPV4:-192.168.123.1}
guest_transit_ipv4=${GUEST_TRANSIT_IPV4:-192.168.123.2}
connection=qemu:///system
network=public-routed
forwarding_config=/etc/sysctl.d/90-libvirt-routing.conf
xml=$(mktemp)
trap 'rm -f "$xml"' EXIT

export LC_ALL=C
network_uuid=$(virsh --connect "$connection" net-uuid "$network" 2>/dev/null || :)
uuid_element=
if [[ -n $network_uuid ]]; then
  uuid_element="  <uuid>$network_uuid</uuid>"
fi
cat >"$xml" <<EOF
<network>
  <name>$network</name>
$uuid_element
  <forward mode='open'/>
  <bridge name='virbr-public' stp='on' delay='0'/>
  <ip address='$host_transit_ipv4' prefix='30'/>
  <ip family='ipv6' address='$IPV6_GATEWAY' prefix='64'/>
  <route family='ipv4' address='$PUBLIC_IPV4' prefix='32'
         gateway='$guest_transit_ipv4'/>
</network>
EOF

if virsh --connect "$connection" net-list --name \
  | grep -Fx "$network" >/dev/null; then
  printf '%s is active. Shut down its attached domains, run ' "$network" >&2
  printf 'virsh net-destroy %s, then rerun this script.\n' "$network" >&2
  exit 1
fi

install -d -m 0755 "$(dirname "$forwarding_config")"
cat >"$forwarding_config" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --quiet --load "$forwarding_config"

virsh --connect "$connection" net-define "$xml"
virsh --connect "$connection" net-autostart "$network"
virsh --connect "$connection" net-start "$network"
virsh --connect "$connection" net-dumpxml "$network"
