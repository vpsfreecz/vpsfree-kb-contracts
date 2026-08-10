{ pkgs }:
let
  kernel = pkgs.linuxPackages.kernel;
  guestPrograms = pkgs.closureInfo {
    rootPaths = [
      pkgs.busybox
      pkgs.dropbear
    ];
  };
  initrd = pkgs.runCommand "kb-kvm-network-guest-initrd" {
    nativeBuildInputs = with pkgs; [
      cpio
      gzip
      kmod
      xz
    ];
  } ''
    root=$TMPDIR/root
    mkdir -p \
      "$root/bin" \
      "$root/dev/pts" \
      "$root/etc/dropbear" \
      "$root/proc" \
      "$root/run" \
      "$root/sys" \
      "$root/tmp" \
      "$root/www"

    while read -r store_path; do
      cp -a --parents "$store_path" "$root"
    done <${guestPrograms}/store-paths
    ln -s ${pkgs.busybox}/bin/busybox "$root/bin/busybox"
    ln -s ${pkgs.dropbear}/bin/dropbear "$root/bin/dropbear"
    ln -s ${pkgs.dropbear}/bin/dropbearkey "$root/bin/dropbearkey"

    while read -r command module; do
      [ "$command" = insmod ] || continue
      relative="''${module#${kernel.modules}}"
      target="$root''${relative%.xz}"
      mkdir -p "$(dirname "$target")"
      xz --decompress --stdout "$module" >"$target"
    done < <(
      modprobe \
        --dirname ${kernel.modules} \
        --set-version ${kernel.modDirVersion} \
        --show-depends \
        --all \
        virtio_pci virtio_net
    )
    depmod --basedir "$root" ${kernel.modDirVersion}

    cp /dev/null "$root/etc/passwd"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' >"$root/etc/passwd"
    printf '%s\n' 'root:x:0:' >"$root/etc/group"

    cp /dev/null "$root/init"
    chmod 0755 "$root/init"
    cat >"$root/init" <<'INIT'
#!/bin/busybox sh
set -eu

exec >/dev/console 2>&1
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /run /root /tmp /var/run /www
mount -t devpts devpts /dev/pts

modprobe virtio_pci
modprobe virtio_net

mode=guest
ipv4=
ipv4_prefix=
gateway4=
public4=
ipv6=
ipv6_prefix=
gateway6=
public6=
upstream4=
upstream6=
for argument in $(cat /proc/cmdline); do
  case "$argument" in
    mode=*) mode=''${argument#mode=} ;;
    ipv4=*) ipv4=''${argument#ipv4=} ;;
    ipv4_prefix=*) ipv4_prefix=''${argument#ipv4_prefix=} ;;
    gateway4=*) gateway4=''${argument#gateway4=} ;;
    public4=*) public4=''${argument#public4=} ;;
    ipv6=*) ipv6=''${argument#ipv6=} ;;
    ipv6_prefix=*) ipv6_prefix=''${argument#ipv6_prefix=} ;;
    gateway6=*) gateway6=''${argument#gateway6=} ;;
    public6=*) public6=''${argument#public6=} ;;
    upstream4=*) upstream4=''${argument#upstream4=} ;;
    upstream6=*) upstream6=''${argument#upstream6=} ;;
  esac
done

ip link set lo up
for _ in $(seq 1 100); do
  [ -e /sys/class/net/eth0 ] && break
  sleep 0.1
done
ip link set eth0 up

if [ -n "$ipv4" ]; then
  ip address add "$ipv4/$ipv4_prefix" dev eth0
fi
if [ -n "$public4" ]; then
  ip address add "$public4/32" dev eth0
fi
if [ -n "$gateway4" ]; then
  if [ -n "$public4" ]; then
    ip route add default via "$gateway4" src "$public4"
  else
    ip route add default via "$gateway4"
  fi
fi

if [ -n "$ipv6" ]; then
  echo 0 >/proc/sys/net/ipv6/conf/all/disable_ipv6
  ip -6 address add "$ipv6/$ipv6_prefix" dev eth0 nodad
fi
if [ -n "$public6" ]; then
  ip -6 address add "$public6/128" dev eth0 nodad
fi
if [ -n "$gateway6" ]; then
  if [ -n "$public6" ]; then
    ip -6 route add default via "$gateway6" src "$public6"
  else
    ip -6 route add default via "$gateway6"
  fi
fi

printf '%s\n' "$mode" > /www/index.html
dropbear -R -E
while true; do
  nc -u -l -p 9000 -e /bin/cat
done &

if [ -n "$upstream4" ]; then
  (
    for _ in $(seq 1 60); do
      wget -q -O /www/outbound4 "http://$upstream4:18080/source" && exit 0
      sleep 1
    done
    exit 1
  ) &
fi
if [ -n "$upstream6" ]; then
  (
    for _ in $(seq 1 60); do
      wget -q -O /www/outbound6 "http://[$upstream6]:18080/source" && exit 0
      sleep 1
    done
    exit 1
  ) &
fi

exec httpd -f -p 80 -h /www
INIT

    mkdir -p "$out"
    (
      cd "$root"
      find . -print0 \
        | sort -z \
        | cpio --null --create --format=newc --quiet \
        | gzip -9n >"$out/initrd.gz"
    )
  '';
in
{
  inherit initrd kernel;
}
