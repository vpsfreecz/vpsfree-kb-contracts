import ../../make-test.nix (
  {
    pkgs,
    lib,
    vpsadminos,
    ...
  }:
  let
    configureFirewalld = builtins.readFile ../../fixtures/firewall/configure-firewalld.sh;
    configureIptables = builtins.readFile ../../fixtures/firewall/configure-iptables.sh;
    configureUfw = builtins.readFile ../../fixtures/firewall/configure-ufw.sh;
    enableNftables = builtins.readFile ../../fixtures/firewall/enable-nftables.sh;
    nftablesConfig = builtins.readFile ../../fixtures/firewall/nftables.conf;
    nixosFirewall = builtins.readFile ../../fixtures/firewall/nixos-firewall.nix;
    switchNixosFirewall = builtins.readFile ../../fixtures/firewall/switch-nixos-firewall.sh;
    testNixosFirewall = builtins.readFile ../../fixtures/firewall/test-nixos-firewall.sh;
    rubySingleQuoted = value: "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";

    commonScript = ''
      require 'base64'
      require 'digest'
      require 'shellwords'

      FIXTURES = {
        'configure-firewalld' => ${rubySingleQuoted configureFirewalld},
        'configure-iptables' => ${rubySingleQuoted configureIptables},
        'configure-ufw' => ${rubySingleQuoted configureUfw},
        'enable-nftables' => ${rubySingleQuoted enableNftables},
        'nftables-config' => ${rubySingleQuoted nftablesConfig},
        'nixos-firewall' => ${rubySingleQuoted nixosFirewall},
        'switch-nixos-firewall' => ${rubySingleQuoted switchNixosFirewall},
        'test-nixos-firewall' => ${rubySingleQuoted testNixosFirewall}
      }.freeze

      EXPECTED_FIXTURE_HASHES = {
        'configure-firewalld' => ${builtins.toJSON (builtins.hashString "sha256" configureFirewalld)},
        'configure-iptables' => ${builtins.toJSON (builtins.hashString "sha256" configureIptables)},
        'configure-ufw' => ${builtins.toJSON (builtins.hashString "sha256" configureUfw)},
        'enable-nftables' => ${builtins.toJSON (builtins.hashString "sha256" enableNftables)},
        'nftables-config' => ${builtins.toJSON (builtins.hashString "sha256" nftablesConfig)},
        'nixos-firewall' => ${builtins.toJSON (builtins.hashString "sha256" nixosFirewall)},
        'switch-nixos-firewall' => ${builtins.toJSON (builtins.hashString "sha256" switchNixosFirewall)},
        'test-nixos-firewall' => ${builtins.toJSON (builtins.hashString "sha256" testNixosFirewall)}
      }.freeze

      LISTENER_UNIT = <<~UNIT.freeze
        [Unit]
        Description=KB firewall listener on TCP %i
        After=network-online.target

        [Service]
        ExecStart=/usr/bin/socat TCP6-LISTEN:%i,ipv6only=0,reuseaddr,fork EXEC:/bin/cat
        Restart=always

        [Install]
        WantedBy=multi-user.target
      UNIT

      NIXOS_SERVICE_MODULE = <<~NIX.freeze
        { pkgs, ... }:
        {
          environment.systemPackages = [ pkgs.curl pkgs.socat ];
          services.openssh.enable = true;
          systemd.services = builtins.listToAttrs (map (port: {
            name = "kb-firewall-listener-''${toString port}";
            value = {
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              serviceConfig = {
                ExecStart = "''${pkgs.socat}/bin/socat TCP6-LISTEN:''${toString port},ipv6only=0,reuseaddr,fork EXEC:''${pkgs.coreutils}/bin/cat";
                Restart = "always";
              };
            };
          }) [ 80 81 443 ]);
        }
      NIX

      configure_examples do |config|
        config.default_order = :defined
      end

      def verify_fixture_hashes
        FIXTURES.each do |name, contents|
          expect(Digest::SHA256.hexdigest(contents)).to eq(
            EXPECTED_FIXTURE_HASHES.fetch(name)
          )
        end
      end

      def ensure_machine
        machine.start unless machine.running?
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
        machine.succeeds('command -v nc')
      end

      def create_container(ct, distribution:, version:, ipv4:, ipv6:, variant: nil)
        variant_arg = variant ? "--variant #{Shellwords.escape(variant)} " : ""
        machine.succeeds(
          "osctl ct new --distribution #{Shellwords.escape(distribution)} " \
          "--version #{Shellwords.escape(version)} #{variant_arg}" \
          "#{Shellwords.escape(ct)}",
          timeout: 600
        )
        machine.succeeds("osctl ct unset start-menu #{Shellwords.escape(ct)}")
        machine.succeeds(
          "osctl ct netif new routed #{Shellwords.escape(ct)} eth0"
        )
        machine.succeeds(
          "osctl ct netif ip add #{Shellwords.escape(ct)} eth0 " \
          "#{Shellwords.escape(ipv4 + '/32')}"
        )
        machine.succeeds(
          "osctl ct netif ip add #{Shellwords.escape(ct)} eth0 " \
          "#{Shellwords.escape(ipv6 + '/128')}"
        )
        machine.succeeds(
          "osctl ct set dns-resolver #{Shellwords.escape(ct)} 10.0.2.3"
        )
        machine.succeeds(
          "osctl ct start #{Shellwords.escape(ct)}",
          timeout: 300
        )
        machine.wait_until_container_online(ct, timeout: 300)
        machine.wait_until_succeeds(
          "ping -c 1 -W 2 #{Shellwords.escape(ipv4)} && " \
          "ping -6 -c 1 -W 2 #{Shellwords.escape(ipv6)}",
          timeout: 120
        )
      end

      def in_container(ct, command, timeout: 600)
        machine.succeeds(
          "osctl ct exec #{Shellwords.escape(ct)} " \
          "bash -lc #{Shellwords.escape(command)}",
          timeout:
        )
      end

      def prepare_apt_packages(ct, packages)
        container_apt_get(
          machine,
          ct,
          'update',
          name: "APT metadata refresh in #{ct}",
          timeout: 1200,
        )

        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          *packages,
          name: "APT package installation in #{ct}",
          environment: { 'DEBIAN_FRONTEND' => 'noninteractive' },
          timeout: 1200,
        )
      end

      def write_container_file(ct, path, contents)
        encoded = Base64.strict_encode64(contents)
        in_container(
          ct,
          "printf %s #{Shellwords.escape(encoded)} | base64 -d > " \
          "#{Shellwords.escape(path)}"
        )
      end

      def run_fixture(ct, name, environment: {}, timeout: 1200)
        encoded = Base64.strict_encode64(FIXTURES.fetch(name))
        command = ['env'] + environment.map { |key, value| "#{key}=#{value}" } + ['bash', '-s']
        machine.succeeds(
          "printf %s #{Shellwords.escape(encoded)} | base64 -d | " \
          "osctl ct exec #{Shellwords.escape(ct)} #{Shellwords.join(command)}",
          timeout:
        )
      end

      def run_apt_fixture(ct, name, timeout: 1200)
        retry_apt_operation(name: "APT fixture #{name} in #{ct}") do
          run_fixture(
            ct,
            name,
            environment: { 'DEBIAN_FRONTEND' => 'noninteractive' },
            timeout:
          )
        end
      end

      def prepare_systemd_listeners(ct, ssh_service:)
        write_container_file(
          ct,
          '/etc/systemd/system/kb-firewall-listener@.service',
          LISTENER_UNIT
        )
        in_container(
          ct,
          "systemctl daemon-reload; systemctl enable --now #{ssh_service}; " \
          'systemctl enable --now kb-firewall-listener@80.service ' \
          'kb-firewall-listener@81.service kb-firewall-listener@443.service; ' \
          "ss -lnt | grep -E ':(22|80|81|443)[[:space:]]'"
        )
      end

      def begin_established_connection(address, family)
        machine.succeeds(
          "rm -f /tmp/kb-firewall-established-#{family}-ready " \
          "/tmp/kb-firewall-established-#{family}-continue " \
          "/tmp/kb-firewall-established-#{family}-result " \
          "/tmp/kb-firewall-established-#{family}.log"
        )
        client = <<~SH
          set -eu
          exec 3<>/dev/tcp/#{address}/81
          printf 'before\\n' >&3
          IFS= read -r reply <&3
          test "$reply" = before
          touch /tmp/kb-firewall-established-#{family}-ready
          while test ! -e /tmp/kb-firewall-established-#{family}-continue; do
            sleep 0.1
          done
          printf 'after\\n' >&3
          IFS= read -r reply <&3
          printf '%s\\n' "$reply" > /tmp/kb-firewall-established-#{family}-result
        SH
        machine.succeeds(
          "setsid -f bash -c #{Shellwords.escape(client)} " \
          "</dev/null >/tmp/kb-firewall-established-#{family}.log 2>&1"
        )
        machine.wait_until_succeeds(
          "test -e /tmp/kb-firewall-established-#{family}-ready",
          timeout: 30
        )
      end

      def begin_established_connections(ipv4, ipv6)
        begin_established_connection(ipv4, 'ipv4')
        begin_established_connection(ipv6, 'ipv6')
      end

      def enable_permissive_connection_tracking(ct)
        in_container(
          ct,
          'iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ' \
          'ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
        )
      end

      def remove_permissive_connection_tracking(ct)
        in_container(
          ct,
          'set -eu; ' \
          'iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ' \
          'ip6tables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ' \
          'if iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ' \
          'then exit 1; fi; ' \
          'if ip6tables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ' \
          'then exit 1; fi'
        )
      end

      def expect_established_connections
        %w[ipv4 ipv6].each do |family|
          machine.succeeds("touch /tmp/kb-firewall-established-#{family}-continue")
          machine.wait_until_succeeds(
            "grep -Fx after /tmp/kb-firewall-established-#{family}-result",
            timeout: 30
          )
        end
      end

      def expect_firewall_behaviour(ct, ipv4:, ipv6:)
        [22, 80, 443].each do |port|
          machine.succeeds(
            "timeout 5 nc -4 -z #{Shellwords.escape(ipv4)} #{port}"
          )
          machine.succeeds(
            "timeout 5 nc -6 -z #{Shellwords.escape(ipv6)} #{port}"
          )
        end
        machine.fails(
          "nc -4 -z -w 3 #{Shellwords.escape(ipv4)} 81",
          timeout: 10
        )
        machine.fails(
          "nc -6 -z -w 3 #{Shellwords.escape(ipv6)} 81",
          timeout: 10
        )
        machine.succeeds("ping -c 1 -W 2 #{Shellwords.escape(ipv4)}")
        machine.succeeds("ping -6 -c 1 -W 2 #{Shellwords.escape(ipv6)}")
        in_container(ct, 'ping -c 1 -W 2 10.0.2.3')
      end

      def restart_and_wait(ct)
        machine.succeeds(
          "osctl ct restart #{Shellwords.escape(ct)}",
          timeout: 300
        )
        machine.wait_until_container_online(ct, timeout: 300)
        in_container(
          ct,
          "until ss -lnt | grep -Eq ':(22|80|443)[[:space:]]'; do sleep 1; done",
          timeout: 120
        )
      end

      def cleanup_container(ct)
        return unless machine.running?

        machine.execute("osctl ct stop --kill #{Shellwords.escape(ct)}")
        machine.execute("osctl ct del --force #{Shellwords.escape(ct)}")
      end

      before(:suite) do
        verify_fixture_hashes
        ensure_machine
      end
    '';

    mkScript = description: body: {
      inherit description;
      tags = [ "kb-runtime" ];
      labels.kbPage = "firewall";
      script = commonScript + body;
    };
  in
  {
    name = "kb-firewall";

    description = ''
      Validate the documented host-firewall configurations on current
      vpsAdminOS distribution images.
    '';

    machine = import (vpsadminos.outPath + "/tests/machines/vpsadminos/with-tank.nix") {
      inherit pkgs;
      config = { };
    };

    testScripts = {
      iptables = mkScript "Apply and persist the documented Debian iptables rules" ''
        CT = 'kb-firewall-iptables'
        IPV4 = '192.0.2.21'
        IPV6 = '2001:db8:21::1'

        after(:suite) { cleanup_container(CT) }

        describe 'the documented Debian iptables firewall' do
          it 'uses the nftables backend and preserves dual-stack policy across restart' do
            create_container(
              CT,
              distribution: 'debian',
              version: 'stable',
              ipv4: IPV4,
              ipv6: IPV6
            )
            prepare_apt_packages(
              CT,
              %w[openssh-server socat curl iptables]
            )
            prepare_systemd_listeners(
              CT,
              ssh_service: 'ssh.service'
            )
            enable_permissive_connection_tracking(CT)
            begin_established_connections(IPV4, IPV6)

            run_apt_fixture(CT, 'configure-iptables')
            in_container(CT, "iptables -V | grep -F '(nf_tables)'")
            in_container(CT, 'iptables -S INPUT | grep -F -- "-P INPUT DROP"')
            in_container(CT, 'ip6tables -S INPUT | grep -F -- "-P INPUT DROP"')
            expect_established_connections
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)

            restart_and_wait(CT)
            in_container(CT, 'systemctl is-active netfilter-persistent')
            in_container(CT, 'iptables -S INPUT | grep -F -- "-P INPUT DROP"')
            in_container(CT, 'ip6tables -S INPUT | grep -F -- "-P INPUT DROP"')
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)
          end
        end
      '';

      nftables = mkScript "Validate, apply and persist the documented Debian nftables rules" ''
        CT = 'kb-firewall-nftables'
        IPV4 = '192.0.2.22'
        IPV6 = '2001:db8:22::1'

        after(:suite) { cleanup_container(CT) }

        describe 'the documented native nftables firewall' do
          it 'filters IPv4 and IPv6 through one inet table across restart' do
            create_container(
              CT,
              distribution: 'debian',
              version: 'stable',
              ipv4: IPV4,
              ipv6: IPV6
            )
            prepare_apt_packages(
              CT,
              %w[openssh-server socat curl nftables iptables]
            )
            prepare_systemd_listeners(
              CT,
              ssh_service: 'ssh.service'
            )
            write_container_file(CT, '/etc/nftables.conf', FIXTURES.fetch('nftables-config'))
            enable_permissive_connection_tracking(CT)
            begin_established_connections(IPV4, IPV6)

            run_apt_fixture(CT, 'enable-nftables')
            in_container(CT, 'nft -c -f /etc/nftables.conf')
            in_container(CT, 'nft list table inet filter | grep -F "policy drop"')
            expect_established_connections
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)

            restart_and_wait(CT)
            in_container(CT, 'systemctl is-active nftables')
            in_container(CT, 'nft list table inet filter | grep -F "policy drop"')
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)
          end
        end
      '';

      ufw = mkScript "Apply and persist the documented Ubuntu UFW rules" ''
        CT = 'kb-firewall-ufw'
        IPV4 = '192.0.2.23'
        IPV6 = '2001:db8:23::1'

        after(:suite) { cleanup_container(CT) }

        describe 'the documented Ubuntu UFW firewall' do
          it 'enforces the selected services for IPv4 and IPv6 across restart' do
            create_container(
              CT,
              distribution: 'ubuntu',
              version: '24.04',
              ipv4: IPV4,
              ipv6: IPV6
            )
            prepare_apt_packages(
              CT,
              %w[openssh-server socat curl iptables]
            )
            prepare_systemd_listeners(
              CT,
              ssh_service: 'ssh.service'
            )
            enable_permissive_connection_tracking(CT)
            begin_established_connections(IPV4, IPV6)
            remove_permissive_connection_tracking(CT)

            run_apt_fixture(CT, 'configure-ufw')
            in_container(CT, "grep -Fx 'IPV6=yes' /etc/default/ufw")
            in_container(CT, "ufw status | grep -F 'Status: active'")
            expect_established_connections
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)

            restart_and_wait(CT)
            in_container(CT, "ufw status | grep -F 'Status: active'")
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)
          end
        end
      '';

      firewalld = mkScript "Apply and persist the documented Fedora firewalld services" ''
        CT = 'kb-firewall-firewalld'
        IPV4 = '192.0.2.24'
        IPV6 = '2001:db8:24::1'

        after(:suite) { cleanup_container(CT) }

        describe 'the documented Fedora firewalld firewall' do
          it 'enforces the public zone for IPv4 and IPv6 across restart' do
            create_container(
              CT,
              distribution: 'fedora',
              version: 'latest',
              ipv4: IPV4,
              ipv6: IPV6
            )
            in_container(
              CT,
              'dnf install -y openssh-server socat curl firewalld',
              timeout: 1200
            )
            prepare_systemd_listeners(
              CT,
              ssh_service: 'sshd.service'
            )
            in_container(
              CT,
              'systemctl enable --now firewalld; ' \
                'firewall-cmd --set-default-zone=trusted; firewall-cmd --reload'
            )
            begin_established_connections(IPV4, IPV6)

            run_fixture(CT, 'configure-firewalld')
            in_container(CT, 'firewall-cmd --get-zone-of-interface=eth0 | grep -Fx public')
            %w[ssh http https].each do |service|
              in_container(
                CT,
                "firewall-cmd --zone=public --query-service=#{service}"
              )
            end
            expect_established_connections
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)

            restart_and_wait(CT)
            in_container(CT, 'systemctl is-active firewalld')
            in_container(CT, 'firewall-cmd --get-zone-of-interface=eth0 | grep -Fx public')
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)
          end
        end
      '';

      nixos = mkScript "Apply and persist the documented NixOS firewall module" ''
        CT = 'kb-firewall-nixos'
        IPV4 = '192.0.2.25'
        IPV6 = '2001:db8:25::1'

        after(:suite) { cleanup_container(CT) }

        describe 'the documented NixOS firewall' do
          it 'persists the declarative dual-stack policy after a test activation' do
            create_container(
              CT,
              distribution: 'nixos',
              version: 'stable',
              variant: 'minimal',
              ipv4: IPV4,
              ipv6: IPV6
            )
            write_container_file(CT, '/etc/nixos/kb-services.nix', NIXOS_SERVICE_MODULE)
            in_container(CT, 'mv /etc/nixos/configuration.nix /etc/nixos/kb-base.nix')
            write_container_file(
              CT,
              '/etc/nixos/configuration.nix',
              <<~NIX
                { lib, ... }:
                {
                  imports = [ ./kb-base.nix ./kb-services.nix ];
                  networking.hostName = lib.mkForce "vps";
                  networking.firewall.enable = lib.mkForce true;
                  networking.firewall.allowedTCPPorts = lib.mkForce [ 22 80 81 443 ];
                }
              NIX
            )
            in_container(
              CT,
              'nixos-rebuild switch --flake /etc/nixos#vps',
              timeout: 1800
            )
            in_container(CT, 'hostname vps; test "$(hostname)" = vps')
            begin_established_connections(IPV4, IPV6)

            write_container_file(
              CT,
              '/etc/nixos/kb-firewall.nix',
              FIXTURES.fetch('nixos-firewall')
            )
            write_container_file(
              CT,
              '/etc/nixos/configuration.nix',
              <<~NIX
                { lib, ... }:
                {
                  imports = [ ./kb-base.nix ./kb-services.nix ./kb-firewall.nix ];
                  networking.hostName = lib.mkForce "vps";
                }
              NIX
            )
            run_fixture(CT, 'test-nixos-firewall', timeout: 1800)
            in_container(
              CT,
              'nix eval --json ' \
                '/etc/nixos#nixosConfigurations.vps.config.networking.firewall.allowedTCPPorts ' \
                '| grep -Fx "[22,80,443]"'
            )
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)

            run_fixture(CT, 'switch-nixos-firewall', timeout: 1800)
            expect_established_connections
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)

            restart_and_wait(CT)
            in_container(
              CT,
              'nix eval --json ' \
                '/etc/nixos#nixosConfigurations.vps.config.networking.firewall.allowedTCPPorts ' \
                '| grep -Fx "[22,80,443]"'
            )
            expect_firewall_behaviour(CT, ipv4: IPV4, ipv6: IPV6)
          end
        end
      '';
    };
  }
)
