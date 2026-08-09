#!/usr/bin/env bash
set -euo pipefail

domain=${DOMAIN_NAME:-kb-kvm-smoke}
xml=$(mktemp)
trap 'rm -f "$xml"' EXIT

cat >"$xml" <<EOF
<domain type='kvm'>
  <name>${domain}</name>
  <memory unit='MiB'>256</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
  </devices>
</domain>
EOF

virsh --connect qemu:///system create --validate "$xml"
virsh --connect qemu:///system domstate "$domain"
virsh --connect qemu:///system destroy "$domain"
