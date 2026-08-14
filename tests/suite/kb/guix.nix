import ../../make-test.nix (
  {
    pkgs,
    lib,
    vpsadminos,
    ...
  }:
  let
    reconfigureSystem = builtins.readFile ../../fixtures/guix/reconfigure-system.sh;
    rubySingleQuoted = value:
      "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";
  in
  {
    name = "kb-guix";

    description = ''
      Validate the documented Guix System reconfiguration on the current
      vpsAdminOS Guix image.
    '';

    machine = import (vpsadminos.outPath + "/tests/machines/vpsadminos/with-tank.nix") {
      inherit pkgs;
      config =
        { ... }:
        {
          # Keep the focused KB contract small enough to coexist with other
          # development VMs on the shared test host.
          boot.qemu.memory = 12 * 1024;

          # The external test consumes the pinned flake source directly.
          # Installer-channel generation requires release revision metadata
          # which is intentionally absent from a local test-framework source.
          os.channel-registration.enable = lib.mkForce false;
        };
    };

    testScripts.reconfigure = {
      description = ''
        Reconfigure the shipped Guix container contract and verify it after a restart
      '';
      tags = [ "kb-runtime" ];
      labels.kbArticle = "guix";
      script = ''
        require 'digest'
        require 'shellwords'

        def reconfigure_system_script
          ${rubySingleQuoted reconfigureSystem}
        end

        def in_guix(command, timeout: 300)
          machine.succeeds(
            "osctl ct exec kb-guix bash -lc #{Shellwords.escape(command)}",
            timeout:
          )
        end

        def wait_for_guix_network
          machine.wait_until_succeeds(
            'ping -c 1 -W 1 192.0.2.2',
            timeout: 180
          )
        end

        def verify_guix_ssh
          machine.succeeds(
            'ssh -o BatchMode=yes -o StrictHostKeyChecking=no ' \
            '-o UserKnownHostsFile=/dev/null -i /root/kb-guix-key ' \
            'root@192.0.2.2 true',
            timeout: 60
          )
        end

        configure_examples do |config|
          config.default_order = :defined
        end

        before(:suite) do
          expect(Digest::SHA256.hexdigest(reconfigure_system_script)).to eq(
            ${builtins.toJSON (builtins.hashString "sha256" reconfigureSystem)}
          )

          machine.start unless machine.running?
          machine.wait_for_osctl_pool('tank')
          machine.wait_until_online
          machine.succeeds(
            'osctl ct new --repository default --vendor vpsadminos ' \
            '--variant minimal --distribution guix --version 20260613 kb-guix',
            timeout: 600
          )
          machine.succeeds('osctl ct netif new routed kb-guix eth0')
          machine.succeeds('osctl ct netif ip add kb-guix eth0 192.0.2.2/32')
          machine.succeeds('osctl ct set dns-resolver kb-guix 10.0.2.3')
          machine.succeeds('osctl ct start kb-guix', timeout: 300)
          wait_for_guix_network

          machine.succeeds(
            "ssh-keygen -q -t ed25519 -N \"\" -f /root/kb-guix-key"
          )
          machine.succeeds(
            "osctl ct exec kb-guix bash -c " \
            "#{Shellwords.escape('install -d -m 0700 /root/.ssh; ' \
            'cat > /root/.ssh/authorized_keys; ' \
            'chmod 0600 /root/.ssh/authorized_keys')} " \
            '< /root/kb-guix-key.pub'
          )
          verify_guix_ssh
        end

        after(:suite) do
          machine.execute('osctl ct stop --kill kb-guix')
          machine.execute('osctl ct del --force kb-guix')
        end

        describe 'the shipped Guix configuration contract' do
          it 'keeps the vpsAdminOS module and generated-network integration' do
            _, system = in_guix('cat /etc/config/system.scm')
            _, platform = in_guix('cat /etc/config/vpsadminos.scm')

            expect(system).to include('(add-to-load-path "/etc/config")')
            expect(system).to include('(use-modules (vpsadminos))')
            expect(platform).to include('(define %ct-file-systems')
            expect(platform).to include('(define vpsadminos-networking')
            expect(platform).to include('/ifcfg.add')
          end

          it 'creates and activates a new generation with the documented command' do
            _, before_generation = in_guix('readlink -f /var/guix/profiles/system')
            in_guix(
              "sed -i 's/(host-name \"guix\")/(host-name \"kb-guix\")/' " \
              '/etc/config/system.scm'
            )
            in_guix(reconfigure_system_script, timeout: 2 * 60 * 60)
            _, after_generation = in_guix('readlink -f /var/guix/profiles/system')

            expect(after_generation.strip).not_to eq(before_generation.strip)
            _, host_name = in_guix('hostname')
            expect(host_name.strip).to eq('kb-guix')
          end

          it 'boots the new generation with networking and SSH available' do
            machine.succeeds('osctl ct restart kb-guix', timeout: 300)
            wait_for_guix_network
            verify_guix_ssh
            _, host_name = in_guix('hostname')
            _, generation = in_guix('readlink -f /var/guix/profiles/system')

            expect(host_name.strip).to eq('kb-guix')
            expect(generation).to match(%r{/gnu/store/.+-system$})
          end
        end
      '';
    };
  }
)
