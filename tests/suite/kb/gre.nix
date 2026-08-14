import ../../make-test.nix (
  {
    pkgs,
    lib,
    vpsadminos,
    ...
  }:
  let
    transientA = builtins.readFile ../../fixtures/gre/configure-transient-a.sh;
    transientB = builtins.readFile ../../fixtures/gre/configure-transient-b.sh;
    interfacesA = builtins.readFile ../../fixtures/gre/interfaces-a;
    interfacesB = builtins.readFile ../../fixtures/gre/interfaces-b;
    rubySingleQuoted = value:
      "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";
  in
  {
    name = "kb-gre";

    description = ''
      Validate transient iproute2 and persistent Debian ifupdown GRE
      configuration between two vpsAdminOS containers.
    '';

    machine = import (vpsadminos.outPath + "/tests/machines/vpsadminos/with-tank.nix") {
      inherit pkgs;
      config = { };
    };

    testScripts.tunnel = {
      description = ''
        Configure both documented GRE endpoints and verify them across restarts
      '';
      tags = [ "kb-runtime" ];
      labels.kbArticle = "gre";
      script = ''
        require 'base64'
        require 'digest'
        require 'shellwords'

        ENDPOINTS = {
          'kb-gre-a' => '192.0.2.10',
          'kb-gre-b' => '198.51.100.20'
        }.freeze

        def transient_a_script
          ${rubySingleQuoted transientA}
        end

        def transient_b_script
          ${rubySingleQuoted transientB}
        end

        def interfaces_a_config
          ${rubySingleQuoted interfacesA}
        end

        def interfaces_b_config
          ${rubySingleQuoted interfacesB}
        end

        def in_container(container, command, timeout: 300)
          machine.succeeds(
            "osctl ct exec #{Shellwords.escape(container)} " \
            "bash -lc #{Shellwords.escape(command)}",
            timeout:
          )
        end

        def run_script(container, script, timeout: 300)
          encoded = Base64.strict_encode64(script)
          machine.succeeds(
            "printf %s #{Shellwords.escape(encoded)} | base64 -d | " \
            "osctl ct exec #{Shellwords.escape(container)} bash -s",
            timeout:
          )
        end

        def install_config(container, path, contents)
          encoded = Base64.strict_encode64(contents)
          command = [
            "printf %s #{Shellwords.escape(encoded)} | base64 -d |",
            "osctl ct exec #{Shellwords.escape(container)}",
            "bash -c #{Shellwords.escape("cat > #{path}")}"
          ].join(' ')
          machine.succeeds(command)
        end

        def wait_for_container(container)
          machine.wait_until_succeeds(
            "osctl ct exec #{Shellwords.escape(container)} " \
            "bash -lc #{Shellwords.escape('command -v ip >/dev/null && ' \
              'command -v ifup >/dev/null && command -v ping >/dev/null')} ",
            timeout: 300
          )
        end

        def expect_bidirectional_ping
          in_container('kb-gre-a', 'ping -c 3 -W 2 10.0.0.2')
          in_container('kb-gre-b', 'ping -c 3 -W 2 10.0.0.1')
        end

        def expect_tunnel(container, local:, remote:, address:)
          _, details = in_container(
            container,
            'ip -details tunnel show gre1; ' \
            'ip -4 -brief address show dev gre1; ' \
            'cat /sys/class/net/gre1/mtu'
          )

          expect(details).to include("remote #{remote}")
          expect(details).to include("local #{local}")
          expect(details).to include(address)
          expect(details.lines.last.strip).to eq('1476')
        end

        configure_examples do |config|
          config.default_order = :defined
        end

        before(:suite) do
          [
            [
              transient_a_script,
              ${builtins.toJSON (builtins.hashString "sha256" transientA)}
            ],
            [
              transient_b_script,
              ${builtins.toJSON (builtins.hashString "sha256" transientB)}
            ],
            [
              interfaces_a_config,
              ${builtins.toJSON (builtins.hashString "sha256" interfacesA)}
            ],
            [
              interfaces_b_config,
              ${builtins.toJSON (builtins.hashString "sha256" interfacesB)}
            ]
          ].each do |sample, expected|
            expect(Digest::SHA256.hexdigest(sample)).to eq(expected)
          end

          machine.start unless machine.running?
          machine.wait_for_osctl_pool('tank')
          machine.wait_until_online
          machine.succeeds('modprobe ip_gre')

          ENDPOINTS.each do |container, address|
            machine.succeeds(
              "osctl ct new --distribution debian #{Shellwords.escape(container)}",
              timeout: 600
            )
            machine.succeeds("osctl ct unset start-menu #{Shellwords.escape(container)}")
            machine.succeeds(
              "osctl ct netif new routed #{Shellwords.escape(container)} eth0"
            )
            machine.succeeds(
              "osctl ct netif ip add #{Shellwords.escape(container)} " \
              "eth0 #{Shellwords.escape(address + '/32')}"
            )
            machine.succeeds(
              "osctl ct set dns-resolver #{Shellwords.escape(container)} 10.0.2.3"
            )
            machine.succeeds(
              "osctl ct start #{Shellwords.escape(container)}",
              timeout: 300
            )
            wait_for_container(container)
          end

          in_container('kb-gre-a', 'ping -c 1 -W 2 198.51.100.20')
          in_container('kb-gre-b', 'ping -c 1 -W 2 192.0.2.10')
        end

        after(:suite) do
          ENDPOINTS.each_key do |container|
            machine.execute("osctl ct stop --kill #{Shellwords.escape(container)}")
            machine.execute("osctl ct del --force #{Shellwords.escape(container)}")
          end
        end

        describe 'the documented transient GRE configuration' do
          it 'creates matching endpoints with the documented addresses and MTU' do
            run_script('kb-gre-a', transient_a_script)
            run_script('kb-gre-b', transient_b_script)

            expect_tunnel(
              'kb-gre-a',
              local: '192.0.2.10',
              remote: '198.51.100.20',
              address: '10.0.0.1/30'
            )
            expect_tunnel(
              'kb-gre-b',
              local: '198.51.100.20',
              remote: '192.0.2.10',
              address: '10.0.0.2/30'
            )
            expect_bidirectional_ping
          end
        end

        describe 'the documented Debian ifupdown configuration' do
          it 'recreates the tunnel from the persistent endpoint stanzas' do
            ENDPOINTS.each_key do |container|
              in_container(container, 'ip tunnel del gre1')
              in_container(
                container,
                "grep -Eq '^source(-directory)?[[:space:]]+" \
                "/etc/network/interfaces.d' /etc/network/interfaces"
              )
            end

            install_config(
              'kb-gre-a',
              '/etc/network/interfaces.d/gre1',
              interfaces_a_config
            )
            install_config(
              'kb-gre-b',
              '/etc/network/interfaces.d/gre1',
              interfaces_b_config
            )

            in_container('kb-gre-a', 'ifup gre1')
            in_container('kb-gre-b', 'ifup gre1')
            expect_bidirectional_ping

            in_container('kb-gre-a', 'ifdown gre1 && ifup gre1')
            in_container('kb-gre-b', 'ifdown gre1 && ifup gre1')
            expect_bidirectional_ping
          end

          it 'brings the tunnel back after both containers restart' do
            machine.succeeds('osctl ct restart kb-gre-a', timeout: 300)
            machine.succeeds('osctl ct restart kb-gre-b', timeout: 300)
            wait_for_container('kb-gre-a')
            wait_for_container('kb-gre-b')

            expect_tunnel(
              'kb-gre-a',
              local: '192.0.2.10',
              remote: '198.51.100.20',
              address: '10.0.0.1/30'
            )
            expect_tunnel(
              'kb-gre-b',
              local: '198.51.100.20',
              remote: '192.0.2.10',
              address: '10.0.0.2/30'
            )
            expect_bidirectional_ping
          end
        end
      '';
    };
  }
)
