import ../../make-test.nix (
  {
    pkgs,
    lib,
    vpsadminos,
    ...
  }:
  let
    deploySystem = builtins.readFile ../../fixtures/guix/deploy-system.scm;
    reconfigureSystem = builtins.readFile ../../fixtures/guix/reconfigure-system.sh;
    rubySingleQuoted = value: "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";
  in
  {
    name = "kb-guix";

    description = ''
      Validate the documented Guix System reconfiguration and deployment on
      the current vpsAdminOS Guix image.
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
        require 'base64'
        require 'digest'
        require 'shellwords'

        def deploy_system_configuration
          ${rubySingleQuoted deploySystem}
        end

        def reconfigure_system_script
          ${rubySingleQuoted reconfigureSystem}
        end

        def in_guix(command, container: 'kb-guix', timeout: 300)
          machine.succeeds(
            "osctl ct exec #{container} bash -lc #{Shellwords.escape(command)}",
            timeout:
          )
        end

        def in_guix_target(command, timeout: 300)
          in_guix(command, container: 'kb-guix-target', timeout:)
        end

        def retry_guix_operation(command, attempts: 3, timeout:)
          attempts.times do |attempt|
            return in_guix(command, timeout:)
          rescue OsVm::CommandFailed => e
            transient_git_error = e.message.match?(
              /Git error:.*(?:SSL error|Resource temporarily unavailable)/m
            )
            raise unless transient_git_error && attempt < attempts - 1

            sleep(15)
          end
        end

        def wait_for_guix_network(address = '192.0.2.2')
          machine.wait_until_succeeds(
            "ping -c 1 -W 1 #{address}",
            timeout: 180
          )
        end

        def verify_guix_ssh(address = '192.0.2.2')
          machine.succeeds(
            'ssh -o BatchMode=yes -o StrictHostKeyChecking=no ' \
            '-o UserKnownHostsFile=/dev/null -i /root/kb-guix-key ' \
            "root@#{address} true",
            timeout: 60
          )
        end

        configure_examples do |config|
          config.default_order = :defined
        end

        before(:suite) do
          expect(Digest::SHA256.hexdigest(deploy_system_configuration)).to eq(
            ${builtins.toJSON (builtins.hashString "sha256" deploySystem)}
          )
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
            'tee /root/.ssh/authorized_keys > /root/.ssh/id_ed25519.pub; ' \
            'chmod 0600 /root/.ssh/authorized_keys; ' \
            'chmod 0644 /root/.ssh/id_ed25519.pub')} " \
            '< /root/kb-guix-key.pub'
          )
          machine.succeeds(
            "osctl ct exec kb-guix bash -c " \
            "#{Shellwords.escape('cat > /root/.ssh/id_ed25519; ' \
            'chmod 0600 /root/.ssh/id_ed25519')} " \
            '< /root/kb-guix-key'
          )
          verify_guix_ssh
        end

        after(:suite) do
          machine.execute('osctl ct stop --kill kb-guix-target')
          machine.execute('osctl ct del --force kb-guix-target')
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
            retry_guix_operation(
              reconfigure_system_script,
              timeout: 2 * 60 * 60
            )
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

        describe 'the documented Guix deployment contract' do
          it 'deploys the complete configuration to a second Guix VPS' do
            machine.succeeds(
              'osctl ct new --repository default --vendor vpsadminos ' \
              '--variant minimal --distribution guix --version 20260613 ' \
              'kb-guix-target',
              timeout: 600
            )
            machine.succeeds('osctl ct netif new routed kb-guix-target eth0')
            machine.succeeds(
              'osctl ct netif ip add kb-guix-target eth0 192.0.2.3/32'
            )
            machine.succeeds(
              'osctl ct set dns-resolver kb-guix-target 10.0.2.3'
            )
            machine.succeeds('osctl ct start kb-guix-target', timeout: 300)
            wait_for_guix_network('192.0.2.3')
            machine.succeeds(
              "osctl ct exec kb-guix-target bash -c " \
              "#{Shellwords.escape('install -d -m 0700 /root/.ssh; ' \
              'cat > /root/.ssh/authorized_keys; ' \
              'chmod 0600 /root/.ssh/authorized_keys')} " \
              '< /root/kb-guix-key.pub'
            )
            verify_guix_ssh('192.0.2.3')

            _, host_key = in_guix_target(
              'cat /etc/ssh/ssh_host_ed25519_key.pub'
            )
            placeholder = 'ssh-ed25519 REPLACE_WITH_TARGET_HOST_KEY'
            expect(deploy_system_configuration.scan(placeholder).length).to eq(1)
            rendered = deploy_system_configuration.sub(
              placeholder,
              host_key.strip
            )
            expect(rendered).to include('(safety-checks? #f)')
            expect(rendered).to include('(allow-downgrades? #f)')
            expect(rendered).to include('(password-authentication? #f)')
            expect(rendered).to include("(permit-root-login 'prohibit-password)")
            encoded = Base64.strict_encode64(rendered)
            in_guix(
              "printf %s #{Shellwords.escape(encoded)} | " \
              'base64 -d > /etc/config/deploy.scm'
            )

            _, before_generation = in_guix_target(
              'readlink -f /var/guix/profiles/system'
            )
            retry_guix_operation(
              'guix time-machine -C /run/current-system/channels.scm -- ' \
              'deploy -L /etc/config /etc/config/deploy.scm',
              timeout: 2 * 60 * 60
            )
            _, after_generation = in_guix_target(
              'readlink -f /var/guix/profiles/system'
            )

            expect(after_generation.strip).not_to eq(before_generation.strip)
            _, host_name = in_guix_target('hostname')
            expect(host_name.strip).to eq('guix-target')

            _, signing_key = in_guix('cat /etc/guix/signing-key.pub')
            _, target_acl = in_guix_target('cat /etc/guix/acl')
            expect(target_acl.gsub(/\s+/, "")).to include(
              signing_key.gsub(/\s+/, "")
            )
          end

          it 'boots the deployed generation with key-only SSH available' do
            machine.succeeds(
              'osctl ct restart kb-guix-target',
              timeout: 300
            )
            wait_for_guix_network('192.0.2.3')
            verify_guix_ssh('192.0.2.3')
            _, host_name = in_guix_target('hostname')
            _, generation = in_guix_target(
              'readlink -f /var/guix/profiles/system'
            )

            expect(host_name.strip).to eq('guix-target')
            expect(generation).to match(%r{/gnu/store/.+-system$})
          end
        end
      '';
    };
  }
)
