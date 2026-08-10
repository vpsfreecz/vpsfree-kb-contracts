#!/usr/bin/env bash
set -euo pipefail

: "${PUBLIC_IPV4:?set PUBLIC_IPV4 to the routed public IPv4 address}"
: "${PUBLIC_IPV6:?set PUBLIC_IPV6 to an unused address from the VPS IPv6 prefix}"

host_transit_ipv4=${HOST_TRANSIT_IPV4:-192.168.123.1}
guest_transit_ipv4=${GUEST_TRANSIT_IPV4:-192.168.123.2}
host_transit_ipv6=${HOST_TRANSIT_IPV6:-fd00:0:0:123::1}
guest_transit_ipv6=${GUEST_TRANSIT_IPV6:-fd00:0:0:123::2}
connection=qemu:///system
network=public-routed
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
  <ip family='ipv6' address='$host_transit_ipv6' prefix='126'/>
  <route family='ipv4' address='$PUBLIC_IPV4' prefix='32'
         gateway='$guest_transit_ipv4'/>
  <route family='ipv6' address='$PUBLIC_IPV6' prefix='128'
         gateway='$guest_transit_ipv6'/>
</network>
EOF

if virsh --connect "$connection" net-list --name \
  | grep -Fx "$network" >/dev/null; then
  printf '%s is active. Shut down its attached domains, run ' "$network" >&2
  printf 'virsh net-destroy %s, then rerun this script.\n' "$network" >&2
  exit 1
fi

virsh --connect "$connection" net-define "$xml"
virsh --connect "$connection" net-autostart "$network"
virsh --connect "$connection" net-start "$network"
virsh --connect "$connection" net-dumpxml "$network"
