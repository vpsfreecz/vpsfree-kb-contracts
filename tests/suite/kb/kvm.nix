import ../../make-test.nix (
  {
    pkgs,
    lib,
    vpsadmin,
    vpsadminos,
    vpsfStatus,
    ...
  }:
  let
    checkPlatform = builtins.readFile ../../fixtures/kvm/check-platform.sh;
    createImages = builtins.readFile ../../fixtures/kvm/create-images.sh;
    installLibvirt = builtins.readFile ../../fixtures/kvm/install-libvirt.sh;
    libvirtSmokeVm = builtins.readFile ../../fixtures/kvm/libvirt-smoke-vm.sh;
    mountReadonlyIso = builtins.readFile ../../fixtures/kvm/mount-readonly-iso.sh;

    common = ''
      require 'base64'
      require 'json'
      require 'shellwords'

      CHECK_PLATFORM = ${builtins.toJSON checkPlatform}
      CREATE_IMAGES = ${builtins.toJSON createImages}
      INSTALL_LIBVIRT = ${builtins.toJSON installLibvirt}
      LIBVIRT_SMOKE_VM = ${builtins.toJSON libvirtSmokeVm}
      MOUNT_READONLY_ISO = ${builtins.toJSON mountReadonlyIso}

      configure_examples do |config|
        config.default_order = :defined
      end

      def run_in_vps(node, vps_id, script, environment: {}, timeout: 1200)
        encoded = Base64.strict_encode64(script)
        command = ['env'] + environment.map { |key, value| "#{key}=#{value}" } + ['bash', '-s']
        shell = [
          "printf %s #{Shellwords.escape(encoded)} | base64 -d |",
          'osctl ct exec',
          Integer(vps_id),
          '--',
          Shellwords.join(command)
        ].join(' ')
        node.succeeds(shell, timeout:)
      end

      def run_command_in_vps(node, vps_id, command, timeout: 300)
        node.succeeds(
          "osctl ct exec #{Integer(vps_id)} -- bash -lc #{Shellwords.escape(command)}",
          timeout:
        )
      end

      def ensure_documentation_vps(services, node, hostname)
        template = services.api_ruby_json(code: <<~RUBY)
          template = OsTemplate.find(1)
          puts JSON.generate(id: template.id, label: template.label)
        RUBY
        expect(template).to eq('id' => 1, 'label' => 'Debian (latest)')

        existing = services.api_ruby_json(code: <<~RUBY)
          vps = Vps.find_by(hostname: #{hostname.dump})
          puts JSON.generate(id: vps&.id)
        RUBY

        vps_id = existing.fetch('id')
        unless vps_id
          result = services.vpsadminctl.succeeds(
            args: %w[vps new],
            parameters: {
              user: 1,
              node: 101,
              os_template: 1,
              hostname:,
              cpu: 2,
              memory: 2048,
              swap: 0,
              diskspace: 8192,
              ipv4: 1,
              ipv4_private: 0,
              ipv6: 0
            },
            timeout: 600
          )
          vps_id = result.fetch('vps').fetch('id')
        end

        current = services.vpsadminctl.succeeds(
          args: ['vps', 'show', vps_id.to_s],
          timeout: 300
        )
        unless current.fetch('vps').fetch('is_running')
          services.vpsadminctl.succeeds(
            args: ['vps', 'start', vps_id.to_s],
            timeout: 600
          )
        end

        node.wait_until_succeeds(
          "osctl ct exec #{Integer(vps_id)} -- true",
          timeout: 900
        )
        vps_id
      end

      def start_cluster
        [services, node1].each { |machine| machine.start unless machine.running? }
        services.wait_for_vpsadmin_api(timeout: 600)
        node1.wait_for_service('nodectld')
        node1.wait_until_succeeds('nodectl status | grep -F "State: running"', timeout: 300)
      end

      def dataset_contract(services, vps_id)
        services.api_ruby_json(code: <<~RUBY)
          vps = Vps.find(#{Integer(vps_id)})
          properties = vps.dataset_in_pool.dataset_properties
                          .where(name: %w[compression recordsize])
                          .pluck(:name, :value, :inherited)
                          .to_h { |name, value, inherited| [name, { value: value, inherited: inherited }] }
          puts JSON.generate(
            dataset: [vps.pool.filesystem, vps.dataset.full_name].join('/'),
            properties: properties
          )
        RUBY
      end
    '';

    mkScript =
      description: hostname: body:
      {
        inherit description;
        tags = [ "kb-runtime" ];
        script = common + ''
          before(:suite) do
            start_cluster
            @vps_id = ensure_documentation_vps(services, node1, ${builtins.toJSON hostname})
          end

          ${body}
        '';
      };

    scripts = {
      platform-defaults = mkScript
        "Verify the default KVM/TUN features and untouched ZFS properties"
        "kb-kvm-defaults"
        ''
          describe 'the vpsFree KVM host defaults' do
            it 'enables KVM and TUN without feature overrides' do
              state = services.api_ruby_json(code: <<~RUBY)
                vps = Vps.find(#{Integer(@vps_id)})
                features = vps.vps_features.where(name: %w[kvm tun]).pluck(:name, :enabled).to_h
                puts JSON.generate(template: vps.os_template.label, features: features)
              RUBY

              expect(state.fetch('template')).to eq('Debian (latest)')
              expect(state.fetch('features')).to eq('kvm' => true, 'tun' => true)
            end

            it 'exposes the documented character devices' do
              _, output = run_in_vps(node1, @vps_id, CHECK_PLATFORM)
              expect(output).to include('KVM and TUN/TAP devices are available.')
            end

            it 'inherits the platform storage defaults' do
              contract = dataset_contract(services, @vps_id)
              properties = contract.fetch('properties')
              expect(properties.dig('compression', 'value')).to be(true)
              expect(properties.dig('recordsize', 'value')).to eq(128 * 1024)

              _, output = node1.succeeds(
                "zfs get -H -o property,value compression,recordsize " \
                "#{Shellwords.escape(contract.fetch('dataset'))}"
              )
              actual = output.lines.map { |line| line.split }.to_h
              expect(actual.fetch('compression')).not_to eq('off')
              expect(actual.fetch('recordsize')).to eq('128K')
            end
          end
        '';

      libvirt = mkScript
        "Install Debian libvirt and start an isolated nested-KVM smoke domain"
        "kb-kvm-libvirt"
        ''
          describe 'the documented Debian libvirt setup' do
            it 'installs and reaches the system libvirt connection' do
              run_in_vps(node1, @vps_id, CHECK_PLATFORM)
              _, output = run_in_vps(node1, @vps_id, INSTALL_LIBVIRT)
              expect(output).to include('Using API: QEMU')
            end

            it 'starts a KVM domain with no guest network' do
              _, output = run_in_vps(node1, @vps_id, LIBVIRT_SMOKE_VM)
              expect(output).to match(/running/i)

              _, xml = run_command_in_vps(
                node1,
                @vps_id,
                "virsh --connect qemu:///system domcapabilities"
              )
              expect(xml).to include('<domain>kvm</domain>')
            end
          end
        '';

      storage = mkScript
        "Verify default ZFS properties and sparse raw/qcow2 image creation"
        "kb-kvm-storage"
        ''
          describe 'the documented disk-image choices' do
            it 'keeps inherited compression and record size unchanged' do
              contract = dataset_contract(services, @vps_id)
              properties = contract.fetch('properties')
              expect(properties.dig('compression', 'value')).to be(true)
              expect(properties.dig('compression', 'inherited')).to be(true)
              expect(properties.dig('recordsize', 'value')).to eq(128 * 1024)
              expect(properties.dig('recordsize', 'inherited')).to be(true)
            end

            it 'creates sparse raw and qcow2 images from the exact sample' do
              run_command_in_vps(
                node1,
                @vps_id,
                'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes qemu-utils',
                timeout: 1200
              )
              run_in_vps(
                node1,
                @vps_id,
                CREATE_IMAGES,
                environment: {
                  'IMAGE_DIR' => '/root/kb-images',
                  'IMAGE_SIZE' => '256M'
                }
              )

              _, output = run_command_in_vps(
                node1,
                @vps_id,
                "qemu-img info --output=json /root/kb-images/guest.raw; " \
                "qemu-img info --output=json /root/kb-images/guest.qcow2; " \
                "stat -c 'allocation raw %s %b' /root/kb-images/guest.raw; " \
                "stat -c 'allocation qcow2 %s %b' /root/kb-images/guest.qcow2"
              )
              expect(output).to include('"format": "raw"')
              expect(output).to include('"format": "qcow2"')

              allocations = output.lines.grep(/^allocation /).to_h do |line|
                _, format, size, blocks = line.split
                [format, { size: Integer(size), allocated: Integer(blocks) * 512 }]
              end
              virtual_size = 256 * 1024 * 1024
              expect(allocations.fetch('raw').fetch(:size)).to eq(virtual_size)
              expect(allocations.fetch('raw').fetch(:allocated)).to be < virtual_size
              expect(allocations.fetch('qcow2').fetch(:size)).to be < virtual_size
              expect(allocations.fetch('qcow2').fetch(:allocated)).to be < virtual_size
            end
          end
        '';

      nfs-locking = mkScript
        "Reproduce an NFSv3 image lock conflict and verify the read-only nolock scope"
        "kb-kvm-nfs"
        ''
          describe 'the constrained NFS installer-ISO workaround' do
            before(:context) do
              services.wait_for_service('nfs-ganesha')
              services.succeeds("rpcinfo -p 127.0.0.1 | grep -Eq '[[:space:]]nfs$'")
              services.fails("rpcinfo -p 127.0.0.1 | grep -Eq '[[:space:]]nlockmgr$'")
              run_command_in_vps(
                node1,
                @vps_id,
                'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes nfs-common qemu-system-x86',
                timeout: 1200
              )
              run_command_in_vps(node1, @vps_id, 'ping -c 1 -W 5 172.16.106.53')
            end

            it 'reports the QEMU lock error on an NFSv3 server without NLM' do
              _, output = run_command_in_vps(node1, @vps_id, <<~'SH')
                set -euo pipefail
                mkdir -p /mnt/installer-iso
                mount -t nfs -o ro,vers=3 172.16.106.53:/srv/kb-installer /mnt/installer-iso
                trap 'umount /mnt/installer-iso' EXIT
                set +e
                output=$(timeout 20 qemu-system-x86_64 \
                  -nodefaults -display none -S -daemonize \
                  -drive file=/mnt/installer-iso/installer.iso,media=cdrom,readonly=on \
                  -pidfile /tmp/kb-qemu-normal.pid 2>&1)
                status=$?
                set -e
                test "$status" -ne 0
                printf '%s\n' "$output"
                grep -Eiq 'failed to (get .*lock|lock byte)|resource temporarily unavailable' \
                  <<<"$output"
              SH
              expect(output).to match(/lock|temporarily unavailable/i)
            end

            it 'uses nolock only for the same read-only installer ISO' do
              _, output = run_in_vps(
                node1,
                @vps_id,
                MOUNT_READONLY_ISO,
                environment: {
                  'NFS_SERVER' => '172.16.106.53',
                  'NFS_EXPORT' => '/srv/kb-installer',
                  'ISO_MOUNTPOINT' => '/mnt/installer-iso'
                }
              )
              expect(output).to include('nfs')
              expect(output).to include('ro')
              expect(output).to include('nolock')

              run_command_in_vps(node1, @vps_id, <<~'SH')
                set -euo pipefail
                trap 'umount /mnt/installer-iso' EXIT
                test -r /mnt/installer-iso/installer.iso
                ! touch /mnt/installer-iso/must-not-be-writable
                qemu-system-x86_64 \
                  -nodefaults -display none -S -daemonize \
                  -drive file=/mnt/installer-iso/installer.iso,media=cdrom,readonly=on \
                  -pidfile /tmp/kb-qemu-nolock.pid
                kill "$(cat /tmp/kb-qemu-nolock.pid)"
              SH
            end
          end
        '';
    };

    nfsServicesModule =
      { pkgs, lib, ... }:
      let
        ganeshaConfig = pkgs.writeText "kb-lockless-ganesha.conf" ''
          NFS_CORE_PARAM {
            Protocols = 3;
            Enable_NLM = false;
            Plugins_Dir = "${pkgs.nfs-ganesha}/lib/ganesha";
          }

          EXPORT {
            Export_Id = 1;
            Path = /srv/kb-installer;
            Protocols = 3;
            Transports = TCP;
            Access_Type = None;
            SecType = sys;

            CLIENT {
              Clients = 198.51.100.0/24;
              Access_Type = RO;
              Squash = All_Squash;
            }

            FSAL {
              Name = VFS;
            }
          }

          LOG {
            Default_Log_Level = INFO;
          }
        '';
      in
      {
        networking.firewall.enable = lib.mkForce false;
        networking.interfaces.eth1.ipv4.routes = [
          {
            address = "198.51.100.0";
            prefixLength = 24;
            via = "172.16.106.41";
          }
        ];
        services.dbus.packages = [ pkgs.nfs-ganesha ];
        services.rpcbind.enable = true;
        systemd.tmpfiles.rules = [
          "d /srv/kb-installer 0755 root root -"
          "d /var/lib/nfs/ganesha 0755 root root -"
        ];
        systemd.services.nfs-ganesha = {
          description = "Lockless NFSv3 fixture for the KVM KB contract";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [
            "dbus.service"
            "network-online.target"
            "rpcbind.service"
            "systemd-tmpfiles-setup.service"
          ];
          requires = [ "rpcbind.service" ];
          preStart = ''
            truncate -s 1048576 /srv/kb-installer/installer.iso
            chmod 0644 /srv/kb-installer/installer.iso
          '';
          serviceConfig = {
            ExecStart =
              "${pkgs.nfs-ganesha}/bin/ganesha.nfsd -F -f ${ganeshaConfig} "
              + "-L STDOUT -p /run/nfs-ganesha.pid";
            Restart = "on-failure";
            RestartSec = 1;
          };
        };
        environment.systemPackages = with pkgs; [
          nfs-utils
          nfs-ganesha
        ];
      };
  in
  (import ../../../cluster/nix/test.nix {
    inherit
      lib
      vpsadmin
      vpsadminos
      vpsfStatus
      ;
    slug = "kb-kvm-runtime";
    topology = "single";
    networkMode = "local";
    bridgeHelper = "";
    certDir = ../../../cluster;
    clusterConfigFile = "";
    sshPubKey = ../../../cluster/placeholder-authorized-key.pub;
    vpsadminSourcePath = vpsadmin.outPath;
    vpsadminosSourcePath = vpsadminos.outPath;
    haveapiSourcePath = "";
    configSourcePath = "";
    notificationTemplatesSourcePath = "";
    webSourcePath = "";
    vpsfStatusSourcePath = "";
    vpsadminGoClientSourcePath = "";
    telegramEnable = "0";
    telegramSecretsSourcePath = "";
    generateCertificates = true;
    testName = "kb-kvm";
    testDescription = ''
      Validate the vpsFree nested-KVM documentation against a vpsAdmin-provisioned
      Debian host on the capture cluster topology.
    '';
    testScripts = scripts;
    extraModules = {
      services = nfsServicesModule;
    };
  }) { inherit pkgs; }
)
