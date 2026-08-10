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
    configureNatPortForwards = builtins.readFile ../../fixtures/kvm/configure-nat-port-forwards.sh;
    configureRoutedNetwork = builtins.readFile ../../fixtures/kvm/configure-routed-network.sh;
    configureStoragePool = builtins.readFile ../../fixtures/kvm/configure-storage-pool.sh;
    installLibvirt = builtins.readFile ../../fixtures/kvm/install-libvirt.sh;
    mountReadonlyIso = builtins.readFile ../../fixtures/kvm/mount-readonly-iso.sh;
    rubySingleQuoted = value:
      "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";
    guestAppliance = import ./kvm-guest.nix { inherit pkgs; };
    guestAssets = pkgs.runCommand "kb-kvm-network-guest-assets" { } ''
      mkdir -p "$out"
      cp ${guestAppliance.kernel}/bzImage "$out/kernel"
      cp ${guestAppliance.initrd}/initrd.gz "$out/initrd.gz"
      cp ${guestAppliance.udpEcho}/bin/udp-echo "$out/udp-echo"
    '';

    common = ''
      require 'base64'
      require 'cgi'
      require 'digest'
      require 'json'
      require 'shellwords'

      def configure_nat_port_forwards_script
        ${rubySingleQuoted configureNatPortForwards}
      end

      def configure_routed_network_script
        ${rubySingleQuoted configureRoutedNetwork}
      end

      def configure_storage_pool_script
        ${rubySingleQuoted configureStoragePool}
      end

      def install_libvirt_script
        ${rubySingleQuoted installLibvirt}
      end

      def mount_readonly_iso_script
        ${rubySingleQuoted mountReadonlyIso}
      end

      def verify_executable_samples
        [
          [
            configure_nat_port_forwards_script,
            ${builtins.toJSON (builtins.hashString "sha256" configureNatPortForwards)}
          ],
          [
            configure_routed_network_script,
            ${builtins.toJSON (builtins.hashString "sha256" configureRoutedNetwork)}
          ],
          [
            configure_storage_pool_script,
            ${builtins.toJSON (builtins.hashString "sha256" configureStoragePool)}
          ],
          [
            install_libvirt_script,
            ${builtins.toJSON (builtins.hashString "sha256" installLibvirt)}
          ],
          [
            mount_readonly_iso_script,
            ${builtins.toJSON (builtins.hashString "sha256" mountReadonlyIso)}
          ]
        ].each do |script, expected|
          expect(Digest::SHA256.hexdigest(script)).to eq(expected)
        end
      end

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
          Shellwords.join(command)
        ].join(' ')
        node.succeeds(shell, timeout:)
      end

      def run_command_in_vps(node, vps_id, command, timeout: 300)
        node.succeeds(
          "osctl ct exec #{Integer(vps_id)} bash -lc #{Shellwords.escape(command)}",
          timeout:
        )
      end

      def documentation_vps_public_ipv4(services, vps_id)
        result = services.api_ruby_json(code: <<~RUBY)
          ip = Vps.find(#{Integer(vps_id)}).ip_addresses
                  .joins(:network)
                  .find_by!(
                    networks: {
                      ip_version: 4,
                      role: Network.roles.fetch('public_access')
                    }
                  )
          puts JSON.generate(ip: ip.ip_addr, prefix: ip.prefix)
        RUBY
        expect(result.fetch('prefix')).to eq(32)
        result.fetch('ip')
      end

      def assign_public_ipv6_prefix(
        services,
        vps_id,
        network_address:,
        label:
      )
        result = services.api_ruby_json(code: <<~RUBY)
          #{api_session_prelude}

          vps = Vps.find(#{Integer(vps_id)})
          netif = vps.network_interfaces.first!
          location = vps.node.location
          network = Network.find_or_initialize_by(
            address: #{network_address.inspect},
            prefix: 64
          )
          if network.new_record?
            network.assign_attributes(
              primary_location: location,
              label: #{label.inspect},
              ip_version: 6,
              role: :public_access,
              managed: true,
              split_access: :no_access,
              split_prefix: 64,
              purpose: :vps
            )
            network.save!
            LocationNetwork.create!(
              location: location,
              network: network,
              primary: true,
              priority: 10,
              autopick: false,
              userpick: false
            )
          end
          prefix = network.ip_addresses.first
          if prefix.nil?
            prefix = IpAddress.register(
              IPAddress.parse(#{(network_address + '/64').inspect}),
              network: network,
              user: vps.user,
              location: location,
              prefix: 64,
              size: 2**64,
              allocate: false
            )
          end
          if prefix.network_interface_id
            host = prefix.host_ip_addresses.where.not(order: nil).first!
          else
            host = prefix.host_ip_addresses.where(order: nil).first!
            chain, = netif.add_route(prefix, host_addrs: [host])
          end
          puts JSON.generate(
            chain_id: chain && chain.id,
            prefix: [prefix.ip_addr, prefix.prefix].join('/'),
            host_ipv6: host.ip_addr,
            host_ip_id: host.id
          )
        RUBY
        wait_for_transaction_chain(services, result.fetch('chain_id')) if result['chain_id']
        result
      end

      def run_nfs_command_in_vps(services, node, vps_id, command, timeout: 90)
        guest = machine_probe(
          node,
          "osctl ct exec #{Integer(vps_id)} bash -lc #{Shellwords.escape(command)}",
          timeout:
        )
        return [guest.fetch(:status), guest.fetch(:output)] if guest[:status] == 0

        diagnostic = {
          guest:,
          exports: machine_probe(
            services,
            'showmount --exports 127.0.0.1',
            timeout: 30
          ),
          ganesha_journal: machine_probe(
            services,
            'journalctl --unit nfs-ganesha --no-pager --lines 200',
            timeout: 30
          )
        }
        expect(guest[:status]).to eq(0), JSON.pretty_generate(diagnostic)
      end

      def wait_for_transaction_chain(services, chain_id)
        chain = services.api_ruby_json(code: <<~RUBY, timeout: 900)
          def bounded_diagnostic_value(value, limit: 2000)
            return value unless value.is_a?(String) && value.length > limit

            half = limit / 2
            value[0, half] + ' ... truncated ... ' + value[-half, half]
          end

          def summarize_transaction_output(output)
            parsed = JSON.parse(output)
            return bounded_diagnostic_value(output) unless parsed.is_a?(Hash)

            parsed.to_h do |direction, phase|
              unless phase.is_a?(Hash)
                next [direction, bounded_diagnostic_value(phase)]
              end

              summary = phase.to_h do |key, value|
                if key == 'backtrace'
                  lines = Array(value).first(8).map do |line|
                    bounded_diagnostic_value(line, limit: 500)
                  end
                  [key, lines]
                else
                  [key, bounded_diagnostic_value(value)]
                end
              end
              [direction, summary]
            end
          rescue JSON::ParserError
            bounded_diagnostic_value(output)
          end

          chain = TransactionChain.find(#{Integer(chain_id)})
          deadline = Time.now + 840
          terminal_states = %w[done failed fatal resolved]
          timed_out = false

          until terminal_states.include?(chain.reload.state)
            if Time.now >= deadline
              timed_out = true
              break
            end

            sleep 1
          end

          transactions = chain.transactions.order(:id).map do |transaction|
            transaction_class = Transaction.for_type(transaction.handle)
            {
              id: transaction.id,
              handle: transaction_class&.t_name || transaction.handle,
              node_id: transaction.node_id,
              queue: transaction.queue,
              done: transaction.done,
              status: transaction.status,
              output: summarize_transaction_output(transaction.output.to_s)
            }
          end
          puts JSON.generate(
            id: chain.id,
            state: chain.state,
            timed_out: timed_out,
            transactions: transactions
          )
        RUBY
        expect(chain.fetch('state')).to eq('done'), JSON.pretty_generate(chain)
        chain
      end

      def ensure_runtime_pool(services)
        pool = services.api_ruby_json(code: <<~RUBY)
          pool = Pool.find_by(node_id: 101, filesystem: 'tank/ct')
          puts JSON.generate(pool && { id: pool.id, label: pool.label })
        RUBY
        return pool if pool

        result = services.vpsadminctl.succeeds(
          args: %w[pool create],
          parameters: {
            node: 101,
            label: 'tank',
            filesystem: 'tank/ct',
            role: 'hypervisor',
            is_open: true,
            max_datasets: 1024,
            refquota_check: true
          },
          timeout: 600
        )
        wait_for_transaction_chain(
          services,
          result.fetch('_meta').fetch('action_state_id')
        )
      end

      def api_session_prelude(user_id = 1)
        <<~RUBY
          user = User.find(#{Integer(user_id)})
          User.current = user
          UserSession.current = UserSession.create!(
            user: user,
            auth_type: 'basic',
            api_ip_addr: '127.0.0.1',
            client_version: 'kb-kvm-runtime'
          )
        RUBY
      end

      def prepare_vm_storage(services, vps_id, mountpoint: '/srv/libvirt/images')
        resize = services.api_ruby_json(code: <<~RUBY)
          #{api_session_prelude}

          vps = Vps.find(#{Integer(vps_id)})
          chain = VpsAdmin::API::Operations::Dataset::UpdateProperties.run(
            vps.dataset_in_pool.dataset,
            { refquota: 6 * 1024 },
            {}
          )
          puts JSON.dump(chain_id: chain.id)
        RUBY
        wait_for_transaction_chain(services, resize.fetch('chain_id'))

        created = services.api_ruby_json(code: <<~RUBY)
          #{api_session_prelude}

          vps = Vps.find(#{Integer(vps_id)})
          chain, dataset = VpsAdmin::API::Operations::Dataset::Create.run(
            'vm-images',
            vps.dataset_in_pool.dataset,
            automount: false,
            properties: { refquota: 2 * 1024 }
          )
          dip = dataset.primary_dataset_in_pool!
          puts JSON.dump(
            chain_id: chain.id,
            dataset_id: dataset.id,
            dataset_in_pool_id: dip.id,
            dataset: [dip.pool.filesystem, dataset.full_name].join('/')
          )
        RUBY
        wait_for_transaction_chain(services, created.fetch('chain_id'))

        mounted = services.api_ruby_json(code: <<~RUBY)
          #{api_session_prelude}

          vps = Vps.find(#{Integer(vps_id)})
          dataset = Dataset.find(#{Integer(created.fetch('dataset_id'))})
          chain, mount = TransactionChains::Vps::MountDataset.fire(
            vps,
            dataset,
            #{mountpoint.inspect},
            mode: 'rw',
            enabled: true
          )
          puts JSON.dump(chain_id: chain.id, mount_id: mount.id)
        RUBY
        wait_for_transaction_chain(services, mounted.fetch('chain_id'))

        created.merge('mountpoint' => mountpoint, 'mount_id' => mounted.fetch('mount_id'))
      end

      def machine_probe(machine, command, timeout:, output_limit: 8000)
        status, output = machine.execute(command, timeout:)
        bounded_output = output.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        if bounded_output.length > output_limit
          bounded_output = bounded_output[-output_limit, output_limit]
        end
        { command:, status:, output: bounded_output }
      rescue StandardError => e
        bounded_error = e.message.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        if bounded_error.length > output_limit
          bounded_error = bounded_error[-output_limit, output_limit]
        end
        {
          command:,
          exception: e.class.name,
          error: bounded_error
        }
      end

      def udp_echo_command(family:, address:, port:, payload:)
        family = Integer(family)
        unless [4, 6].include?(family)
          raise ArgumentError, "unsupported IP family #{family}"
        end

        Shellwords.join(
          [
            ${builtins.toJSON "${guestAppliance.udpEcho}/bin/udp-echo"},
            'client',
            family.to_s,
            address,
            Integer(port).to_s,
            payload
          ]
        )
      end

      def wait_for_udp_echo(
        services,
        node,
        vps_id,
        family:,
        public_address:,
        public_port:,
        guest_address:,
        guest_port:,
        payload:,
        timeout:
      )
        family = Integer(family)
        command = udp_echo_command(
          family:,
          address: public_address,
          port: public_port,
          payload:
        )
        deadline = Time.now + timeout
        last_probe = nil

        loop do
          last_probe = machine_probe(services, command, timeout: 10)
          return last_probe if last_probe[:status] == 0

          break if Time.now >= deadline

          sleep 1
        end

        vps_probe = lambda do |probe_command, output_limit: 8000|
          machine_probe(
            node,
            "osctl ct exec #{Integer(vps_id)} bash -lc " \
            "#{Shellwords.escape(probe_command)}",
            timeout: 60,
            output_limit:
          )
        end
        direct_command = Shellwords.join(
          [
            '/usr/local/libexec/kb-kvm-udp-echo',
            'client',
            family.to_s,
            guest_address,
            Integer(guest_port).to_s,
            payload
          ]
        )
        route_tool = family == 6 ? 'ip -6' : 'ip -4'
        diagnostic = {
          endpoint: last_probe,
          client_route: machine_probe(
            services,
            "#{route_tool} address show; " \
            "#{route_tool} route get #{Shellwords.escape(public_address)}",
            timeout: 30
          ),
          direct_guest: vps_probe.call(direct_command),
          vps_network: vps_probe.call(
            'ip -brief address; ip -4 route show; ip -6 route show'
          ),
          vps_firewall: vps_probe.call(
            [
              'iptables -w -t nat -L VPSFREE_KVM_DNAT -n -v -x',
              'iptables -w -t filter -L VPSFREE_KVM_FWD -n -v -x',
              'ip6tables -w -t nat -L VPSFREE_KVM_DNAT -n -v -x',
              'ip6tables -w -t filter -L VPSFREE_KVM_FWD -n -v -x',
              'ip6tables-save -t nat',
              'ip6tables-save -t filter'
            ].join('; '),
            output_limit: 16_000
          ),
          domain: vps_probe.call(
            'virsh --connect qemu:///system domstate nat-guest; ' \
            'virsh --connect qemu:///system domiflist nat-guest'
          ),
          console: vps_probe.call(
            'tail -n 200 /var/log/libvirt/qemu/nat-guest-console.log'
          ),
          qemu: vps_probe.call(
            'tail -n 100 /var/log/libvirt/qemu/nat-guest.log'
          )
        }
        expect(last_probe&.fetch(:status, nil)).to eq(0), JSON.pretty_generate(diagnostic)
      end

      def configure_nat_udp_forwards(node, vps_id, public_ipv4:, public_ipv6:)
        run_command_in_vps(node, vps_id, <<~SH)
          set -euo pipefail
          sed -i '/^ipv[46] udp /d' /etc/libvirt/port-forwards.conf
          cat >>/etc/libvirt/port-forwards.conf <<'EOF'
          ipv4 udp #{public_ipv4} 5353 192.168.124.10 9000
          ipv6 udp #{public_ipv6} 5353 fd5f:6d2e:9c4a:124::10 9001
          EOF
          /etc/libvirt/hooks/network.d/50-port-forwards \
            dualstack-nat started begin -
        SH
      end

      def wait_for_guest_command(
        services,
        node,
        vps_id,
        domain,
        command,
        timeout:
      )
        deadline = Time.now + timeout
        last_probe = nil

        loop do
          last_probe = machine_probe(services, command, timeout: 30)
          return last_probe if last_probe[:status] == 0

          break if Time.now >= deadline

          sleep 1
        end

        escaped_domain = Shellwords.escape(domain)
        console_log = Shellwords.escape(
          "/var/log/libvirt/qemu/#{domain}-console.log"
        )
        qemu_log = Shellwords.escape("/var/log/libvirt/qemu/#{domain}.log")
        vps_probe = lambda do |probe_command, output_limit: 8000|
          machine_probe(
            node,
            "osctl ct exec #{Integer(vps_id)} bash -lc " \
            "#{Shellwords.escape(probe_command)}",
            timeout: 60,
            output_limit:
          )
        end
        diagnostic = {
          endpoint: last_probe,
          domain: vps_probe.call(
            [
              "virsh --connect qemu:///system domstate #{escaped_domain}",
              "virsh --connect qemu:///system domiflist #{escaped_domain}"
            ].join('; '),
            output_limit: 4000
          ),
          network: vps_probe.call(
            [
              'ip -brief address',
              'ip -4 route show',
              'ip -6 route show'
            ].join('; ')
          ),
          firewall: vps_probe.call(
            [
              'iptables -t nat -S',
              'iptables -t filter -S',
              'ip6tables -t filter -S'
            ].join('; ')
          ),
          console: vps_probe.call("tail -n 200 #{console_log}"),
          qemu: vps_probe.call("tail -n 100 #{qemu_log}")
        }
        expect(last_probe&.fetch(:status, nil)).to eq(0), JSON.pretty_generate(diagnostic)
      end

      def wait_for_documentation_vps(services, node, vps_id, timeout: 180)
        deadline = Time.now + timeout
        last_exec = nil

        loop do
          last_exec = machine_probe(
            node,
            "osctl ct exec #{Integer(vps_id)} true",
            timeout: 30
          )
          return true if last_exec[:status] == 0

          break if Time.now >= deadline

          sleep 2
        end

        osctl_show = machine_probe(
          node,
          "osctl ct show #{Integer(vps_id)}",
          timeout: 30
        )
        container_log = machine_probe(
          node,
          "osctl ct log cat #{Integer(vps_id)} | tail -n 200",
          timeout: 30
        )
        api_state = machine_probe(
          services,
          "vpsadminctl --raw vps show #{Integer(vps_id)}",
          timeout: 60
        )
        diagnostic = {
          vps_id: Integer(vps_id),
          last_exec:,
          api_state:,
          osctl_show:,
          container_log:
        }
        expect(last_exec[:status]).to eq(0), JSON.pretty_generate(diagnostic)
      end

      def create_documentation_vps(
        services,
        node,
        hostname,
        ipv4: 1,
        ipv4_private: 0,
        ipv6: 0,
        memory: 2048
      )
        template = services.api_ruby_json(code: <<~RUBY)
          template = OsTemplate.find(1)
          puts JSON.generate(id: template.id, label: template.label)
        RUBY
        expect(template).to eq('id' => 1, 'label' => 'Debian (latest)')

        result = services.vpsadminctl.succeeds(
          args: %w[vps new],
          parameters: {
            user: 1,
            node: 101,
            os_template: 1,
            hostname:,
            cpu: 2,
            memory:,
            swap: 0,
            diskspace: 8192,
            ipv4:,
            ipv4_private:,
            ipv6:,
            start: true
          },
          timeout: 600
        )
        vps_id = result.fetch('vps').fetch('id')
        wait_for_transaction_chain(
          services,
          result.fetch('_meta').fetch('action_state_id')
        )

        wait_for_documentation_vps(services, node, vps_id)
        vps_id
      end

      def route_public_ipv4_via_private(services, vps_id)
        result = services.api_ruby_json(code: <<~RUBY)
          #{api_session_prelude}

          vps = Vps.find(#{Integer(vps_id)})
          netif = vps.network_interfaces.first!
          private_ip = netif.ip_addresses
                            .joins(:network)
                            .find_by!(networks: { ip_version: 4, role: :private_access })
          via = private_ip.host_ip_addresses.where.not(order: nil).first!
          public_ip = IpAddress
                        .joins(:network)
                        .where(
                          network_interface_id: nil,
                          networks: { ip_version: 4, role: :public_access }
                        )
                        .order(:id)
                        .first!
          chain, = netif.add_route(public_ip, via: via)
          puts JSON.generate(
            chain_id: chain.id,
            private_ipv4: private_ip.ip_addr,
            public_ipv4: public_ip.ip_addr,
            route_via_id: via.id
          )
        RUBY
        wait_for_transaction_chain(services, result.fetch('chain_id'))
        result
      end

      def route_public_ipv6_prefix(services, vps_id, via_id:)
        result = services.api_ruby_json(code: <<~RUBY)
          #{api_session_prelude}

          vps = Vps.find(#{Integer(vps_id)})
          netif = vps.network_interfaces.first!
          location = vps.node.location
          via = HostIpAddress.find(#{Integer(via_id)})
          network = Network.find_or_initialize_by(
            address: '2001:db8:200::',
            prefix: 64
          )
          if network.new_record?
            network.assign_attributes(
              primary_location: location,
              label: 'KVM routed IPv6 /64 fixture',
              ip_version: 6,
              role: :public_access,
              managed: true,
              split_access: :no_access,
              split_prefix: 64,
              purpose: :vps
            )
            network.save!
            LocationNetwork.create!(
              location: location,
              network: network,
              primary: true,
              priority: 10,
              autopick: false,
              userpick: false
            )
          end
          prefix = network.ip_addresses.first
          if prefix.nil?
            prefix = IpAddress.register(
              IPAddress.parse('2001:db8:200::/64'),
              network: network,
              user: vps.user,
              location: location,
              prefix: 64,
              size: 2**64,
              allocate: false
            )
          end
          chain, = netif.add_route(prefix, via: via)
          puts JSON.generate(
            chain_id: chain.id,
            prefix: [prefix.ip_addr, prefix.prefix].join('/'),
            ipv6_gateway: '2001:db8:200::1',
            via_ipv6: via.ip_addr,
            route_via_id: via.id,
            guest_ipv6: '2001:db8:200::10'
          )
        RUBY
        wait_for_transaction_chain(services, result.fetch('chain_id'))
        result
      end

      def install_guest_appliance(node, vps_id)
        run_command_in_vps(node, vps_id, <<~'SH', timeout: 1200)
          set -euo pipefail
          export DEBIAN_FRONTEND=noninteractive
          apt-get install --yes curl
          install -d -m 0755 /var/lib/libvirt/boot
          install -d -m 0755 /usr/local/libexec
          curl --fail --show-error --silent \
            http://172.16.106.53:18080/assets/kernel \
            --output /var/lib/libvirt/boot/kb-kvm-kernel
          curl --fail --show-error --silent \
            http://172.16.106.53:18080/assets/initrd.gz \
            --output /var/lib/libvirt/boot/kb-kvm-initrd.gz
          curl --fail --show-error --silent \
            http://172.16.106.53:18080/assets/udp-echo \
            --output /usr/local/libexec/kb-kvm-udp-echo
          chmod 0755 /usr/local/libexec/kb-kvm-udp-echo
        SH
      end

      def define_network_guest(node, vps_id, name:, network:, mac:, cmdline:)
        xml = <<~XML
          <domain type='kvm'>
            <name>#{CGI.escapeHTML(name)}</name>
              <memory unit='MiB'>256</memory>
            <vcpu>1</vcpu>
            <os>
              <type arch='x86_64'>hvm</type>
              <kernel>/var/lib/libvirt/boot/kb-kvm-kernel</kernel>
              <initrd>/var/lib/libvirt/boot/kb-kvm-initrd.gz</initrd>
              <cmdline>#{CGI.escapeHTML(cmdline)}</cmdline>
            </os>
            <devices>
              <interface type='network'>
                <mac address='#{CGI.escapeHTML(mac)}'/>
                <source network='#{CGI.escapeHTML(network)}'/>
                <model type='virtio'/>
              </interface>
              <console type='file'>
                <source path='/var/log/libvirt/qemu/#{CGI.escapeHTML(name)}-console.log'/>
                <target type='serial' port='0'/>
              </console>
            </devices>
          </domain>
        XML
        run_in_vps(
          node,
          vps_id,
          "printf '%s' #{Shellwords.escape(xml)} > /tmp/#{Shellwords.escape(name)}.xml\n" \
          "virsh --connect qemu:///system define /tmp/#{Shellwords.escape(name)}.xml"
        )
      end

      def start_cluster
        [services, node1].each { |machine| machine.start unless machine.running? }
        services.wait_for_vpsadmin_api(timeout: 600)
        node1.wait_for_service('nodectld')
        node1.wait_until_succeeds('nodectl status | grep -F "State: running"', timeout: 300)
        ensure_runtime_pool(services)
        wait_until_block_succeeds(name: 'node 101 ready in API') do
          current = services.vpsadminctl.succeeds(args: %w[node show 101])
          api_node = current.fetch('node')

          api_node.fetch('status') == true && api_node.fetch('pool_status') == true
        end
      end

      def prepare_network_test_backbone(services, node)
        services.wait_for_service('nginx')
        services.succeeds('curl --fail --silent http://127.0.0.1:18080/assets/kernel >/dev/null')
        services.succeeds(
          'ip -6 address replace 2001:db8:ffff::53/64 dev eth1 && ' \
          'ip -6 route replace 2001:db8:100::/64 via 2001:db8:ffff::41 dev eth1 && ' \
          'ip -6 route replace 2001:db8:101::/64 via 2001:db8:ffff::41 dev eth1 && ' \
          'ip -6 route replace 2001:db8:200::/64 via 2001:db8:ffff::41 dev eth1'
        )
        node.succeeds(
          'ip -6 address replace 2001:db8:ffff::41/64 dev eth1 && ' \
          'sysctl -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 && ' \
          '(iptables -w -t nat -C POSTROUTING -s 10.106.0.0/24 -o eth0 ' \
          '-j MASQUERADE 2>/dev/null || ' \
          'iptables -w -t nat -A POSTROUTING -s 10.106.0.0/24 -o eth0 -j MASQUERADE)'
        )
      end

      def dataset_contract(services, dataset_id)
        services.api_ruby_json(code: <<~RUBY)
          dataset = Dataset.find(#{Integer(dataset_id)})
          dip = dataset.primary_dataset_in_pool!
          properties = dip.dataset_properties
                          .where(name: %w[compression recordsize])
                          .pluck(:name, :value, :inherited)
                          .to_h { |name, value, inherited| [name, { value: value, inherited: inherited }] }
          puts JSON.generate(
            dataset: [dip.pool.filesystem, dataset.full_name].join('/'),
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
            verify_executable_samples
          end

          ${
            if hostname == null then
              ""
            else
              ''
                before(:suite) do
                  start_cluster
                  @vps_id = create_documentation_vps(services, node1, ${builtins.toJSON hostname})
                end
              ''
          }

          ${body}
        '';
      };

    scripts = {
      platform-defaults = mkScript
        "Verify the default KVM/TUN features and device mappings"
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

            it 'exposes the feature device mappings in the VPS' do
              run_command_in_vps(
                node1,
                @vps_id,
                'test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm && ' \
                'test -c /dev/net/tun'
              )
            end
          end
        '';

      libvirt = mkScript
        "Install Debian libvirt and verify direct KVM capabilities"
        "kb-kvm-libvirt"
        ''
          describe 'the documented Debian libvirt setup' do
            it 'installs and reaches the system libvirt connection' do
              _, output = run_in_vps(node1, @vps_id, install_libvirt_script)
              expect(output).to include('Using API: QEMU')
            end

            it 'reports KVM support without creating a domain' do
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
        "Verify the recommended subdataset-backed libvirt storage pool"
        "kb-kvm-storage"
        ''
          describe 'the documented libvirt storage pool' do
            before(:context) do
              @storage = prepare_vm_storage(services, @vps_id)
              run_in_vps(node1, @vps_id, install_libvirt_script)
            end

            it 'mounts a subdataset with inherited ZFS defaults' do
              contract = dataset_contract(services, @storage.fetch('dataset_id'))
              properties = contract.fetch('properties')
              expect(contract.fetch('dataset')).to eq(@storage.fetch('dataset'))
              expect(properties.dig('compression', 'value')).to be(true)
              expect(properties.dig('compression', 'inherited')).to be(true)
              expect(properties.dig('recordsize', 'value')).to eq(128 * 1024)
              expect(properties.dig('recordsize', 'inherited')).to be(true)

              _, actual = node1.succeeds(
                "zfs get -H -o property,value compression,recordsize " \
                "#{Shellwords.escape(contract.fetch('dataset'))}"
              )
              zfs_properties = actual.lines.map { |line| line.split }.to_h
              expect(zfs_properties.fetch('compression')).not_to eq('off')
              expect(zfs_properties.fetch('recordsize')).to eq('128K')

              _, mountpoint = run_command_in_vps(
                node1,
                @vps_id,
                'findmnt --noheadings --output TARGET --target /srv/libvirt/images'
              )
              expect(mountpoint.strip).to eq('/srv/libvirt/images')
            end

            it 'lets libvirt manage volumes on the mounted subdataset' do
              _, pool_info = run_in_vps(node1, @vps_id, configure_storage_pool_script)
              expect(pool_info).to match(/State:\s+running/)
              expect(pool_info).to match(/Autostart:\s+yes/)

              _, pool_xml = run_command_in_vps(
                node1,
                @vps_id,
                'virsh --connect qemu:///system pool-dumpxml vm-images'
              )
              expect(pool_xml).to include('<path>/srv/libvirt/images</path>')

              _, volume = run_command_in_vps(
                node1,
                @vps_id,
                'virsh --connect qemu:///system vol-create-as ' \
                'vm-images kb-volume.raw 1600M --allocation 0 --format raw && ' \
                'virsh --connect qemu:///system vol-path ' \
                '--pool vm-images kb-volume.raw && ' \
                'stat --format %s /srv/libvirt/images/kb-volume.raw && ' \
                'findmnt --noheadings --output TARGET ' \
                '--target /srv/libvirt/images/kb-volume.raw'
              )
              expect(volume).to include('/srv/libvirt/images/kb-volume.raw')
              capacity = Integer(volume.lines[-2])
              quota = 2 * 1024 * 1024 * 1024
              expect(capacity).to eq(1600 * 1024 * 1024)
              expect(quota - capacity).to be >= quota / 5
              expect(volume.lines.last.strip).to eq('/srv/libvirt/images')
            end
          end
        '';

      networking = mkScript
        "Verify NAT port forwarding and routed IPv4/IPv6 guests"
        null
        ''
          before(:suite) do
            start_cluster
            prepare_network_test_backbone(services, node1)

            @nat_vps_id = create_documentation_vps(
              services,
              node1,
              'kb-kvm-nat',
              memory: 1024
            )
            @nat_public_ipv4 = documentation_vps_public_ipv4(services, @nat_vps_id)
            @nat_ipv6 = assign_public_ipv6_prefix(
              services,
              @nat_vps_id,
              network_address: '2001:db8:100::',
              label: 'KVM NAT IPv6 /64 fixture'
            )
            @nat_public_ipv6 = @nat_ipv6.fetch('host_ipv6')
            run_in_vps(node1, @nat_vps_id, install_libvirt_script)
            run_command_in_vps(node1, @nat_vps_id, <<~'SH')
              virsh --connect qemu:///system net-autostart default
              if ! virsh --connect qemu:///system net-list --name \
                | grep -Fx default >/dev/null; then
                virsh --connect qemu:///system net-start default
              fi
            SH
            install_guest_appliance(node1, @nat_vps_id)
            define_network_guest(
              node1,
              @nat_vps_id,
              name: 'nat-guest',
              network: 'dualstack-nat',
              mac: '52:54:00:12:20:10',
              cmdline: [
                'console=ttyS0',
                'mode=nat',
                'ipv4=192.168.124.10',
                'ipv4_prefix=24',
                'gateway4=192.168.124.1',
                'ipv6=fd5f:6d2e:9c4a:124::10',
                'ipv6_prefix=64',
                'gateway6=fd5f:6d2e:9c4a:124::1',
                'upstream4=172.16.106.53',
                'upstream6=2001:db8:ffff::53'
              ].join(' ')
            )
            run_in_vps(
              node1,
              @nat_vps_id,
              configure_nat_port_forwards_script,
              environment: {
                'PUBLIC_IPV4' => @nat_public_ipv4,
                'PUBLIC_IPV6' => @nat_public_ipv6,
                'GUEST_IPV4' => '192.168.124.10',
                'GUEST_IPV6' => 'fd5f:6d2e:9c4a:124::10'
              }
            )
            run_command_in_vps(
              node1,
              @nat_vps_id,
              'virsh --connect qemu:///system start nat-guest'
            )

            @routed_vps_id = create_documentation_vps(
              services,
              node1,
              'kb-kvm-routed',
              ipv4: 0,
              ipv4_private: 1,
              memory: 1024
            )
            @routed_ipv4 = route_public_ipv4_via_private(services, @routed_vps_id)
            @routed_primary_ipv6 = assign_public_ipv6_prefix(
              services,
              @routed_vps_id,
              network_address: '2001:db8:101::',
              label: 'KVM routed primary IPv6 /64 fixture'
            )
            @routed_ipv6 = route_public_ipv6_prefix(
              services,
              @routed_vps_id,
              via_id: @routed_primary_ipv6.fetch('host_ip_id')
            )
            run_in_vps(node1, @routed_vps_id, install_libvirt_script)
            install_guest_appliance(node1, @routed_vps_id)
            run_in_vps(
              node1,
              @routed_vps_id,
              configure_routed_network_script,
              environment: {
                'PUBLIC_IPV4' => @routed_ipv4.fetch('public_ipv4'),
                'IPV6_GATEWAY' => @routed_ipv6.fetch('ipv6_gateway'),
                'HOST_TRANSIT_IPV4' => '192.0.2.1',
                'GUEST_TRANSIT_IPV4' => '192.0.2.2'
              }
            )
            define_network_guest(
              node1,
              @routed_vps_id,
              name: 'routed-guest',
              network: 'public-routed',
              mac: '52:54:00:12:30:10',
              cmdline: [
                'console=ttyS0',
                'mode=routed',
                'ipv4=192.0.2.2',
                'ipv4_prefix=30',
                'gateway4=192.0.2.1',
                "public4=#{@routed_ipv4.fetch('public_ipv4')}",
                "ipv6=#{@routed_ipv6.fetch('guest_ipv6')}",
                'ipv6_prefix=64',
                "gateway6=#{@routed_ipv6.fetch('ipv6_gateway')}",
                'upstream4=172.16.106.53',
                'upstream6=2001:db8:ffff::53'
              ].join(' ')
            )
            run_command_in_vps(
              node1,
              @routed_vps_id,
              'virsh --connect qemu:///system start routed-guest'
            )
          end

          describe 'public VPS addresses forwarded through dual-stack libvirt NAT' do
            it 'exposes IPv4 and IPv6 services while preserving outbound access' do
              _, network_xml = run_command_in_vps(
                node1,
                @nat_vps_id,
                'virsh --connect qemu:///system net-dumpxml dualstack-nat'
              )
              _, default_xml = run_command_in_vps(
                node1,
                @nat_vps_id,
                'virsh --connect qemu:///system net-dumpxml default'
              )
              _, active_networks = run_command_in_vps(
                node1,
                @nat_vps_id,
                'virsh --connect qemu:///system net-list --name'
              )
              expect(active_networks.lines.map(&:strip)).to include(
                'default',
                'dualstack-nat'
              )
              expect(default_xml).to include(
                "address='192.168.122.1'"
              )
              expect(network_xml).to include("<nat ipv6='yes'>")
              expect(network_xml).to include(
                "address='192.168.124.1' prefix='24'"
              )
              expect(network_xml).to include(
                "address='fd5f:6d2e:9c4a:124::1' prefix='64'"
              )
              wait_for_guest_command(
                services,
                node1,
                @nat_vps_id,
                'nat-guest',
                "curl --fail --silent http://#{@nat_public_ipv4}/ | grep -Fx nat",
                timeout: 180
              )
              services.succeeds(
                "ssh-keyscan -T 5 -p 2222 #{@nat_public_ipv4} 2>/dev/null | " \
                "grep -F '[#{@nat_public_ipv4}]:2222'"
              )
              wait_for_guest_command(
                services,
                node1,
                @nat_vps_id,
                'nat-guest',
                "curl --fail --silent http://#{@nat_public_ipv4}/outbound4 " \
                "| grep -Fx #{@nat_public_ipv4}",
                timeout: 180
              )
              wait_for_guest_command(
                services,
                node1,
                @nat_vps_id,
                'nat-guest',
                "curl --globoff --fail --silent http://[#{@nat_public_ipv6}]/ " \
                '| grep -Fx nat',
                timeout: 180
              )
              services.succeeds(
                "ssh-keyscan -6 -T 5 -p 2222 #{@nat_public_ipv6} 2>/dev/null | " \
                "grep -F '[#{@nat_public_ipv6}]:2222'"
              )
              wait_for_guest_command(
                services,
                node1,
                @nat_vps_id,
                'nat-guest',
                "curl --globoff --fail --silent " \
                "http://[#{@nat_public_ipv6}]/outbound6 " \
                "| grep -Fx #{@nat_public_ipv6}",
                timeout: 180
              )
            end

            it 'forwards additional UDP ports over IPv4 and IPv6' do
              configure_nat_udp_forwards(
                node1,
                @nat_vps_id,
                public_ipv4: @nat_public_ipv4,
                public_ipv6: @nat_public_ipv6
              )
              wait_for_udp_echo(
                services,
                node1,
                @nat_vps_id,
                family: 4,
                public_address: @nat_public_ipv4,
                public_port: 5353,
                guest_address: '192.168.124.10',
                guest_port: 9000,
                payload: 'kb-udp',
                timeout: 60
              )
              wait_for_udp_echo(
                services,
                node1,
                @nat_vps_id,
                family: 6,
                public_address: @nat_public_ipv6,
                public_port: 5353,
                guest_address: 'fd5f:6d2e:9c4a:124::10',
                guest_port: 9001,
                payload: 'kb-udp6',
                timeout: 60
              )
            end

            it 'rejects invalid records without replacing active forwards' do
              configure_nat_udp_forwards(
                node1,
                @nat_vps_id,
                public_ipv4: @nat_public_ipv4,
                public_ipv6: @nat_public_ipv6
              )
              run_command_in_vps(node1, @nat_vps_id, <<~SH)
                set -euo pipefail

                assert_rejected_without_changes() {
                  local description=$1
                  local before_v4_nat before_v4_filter
                  local before_v6_nat before_v6_filter
                  before_v4_nat=$(iptables -t nat -S)
                  before_v4_filter=$(iptables -t filter -S)
                  before_v6_nat=$(ip6tables -t nat -S)
                  before_v6_filter=$(ip6tables -t filter -S)
                  if /etc/libvirt/hooks/network.d/50-port-forwards \
                      dualstack-nat started begin -; then
                    printf '%s was accepted\n' "$description" >&2
                    exit 1
                  fi
                  test "$(iptables -t nat -S)" = "$before_v4_nat"
                  test "$(iptables -t filter -S)" = "$before_v4_filter"
                  test "$(ip6tables -t nat -S)" = "$before_v6_nat"
                  test "$(ip6tables -t filter -S)" = "$before_v6_filter"
                }

                cat >>/etc/libvirt/port-forwards.conf <<'EOF'
                ipv6 udp not:an:address 5354 fd5f:6d2e:9c4a:124::10 9001
                EOF
                assert_rejected_without_changes 'Malformed IPv6 address'
                sed -i '/not:an:address/d' /etc/libvirt/port-forwards.conf

                cat >>/etc/libvirt/port-forwards.conf <<'EOF'
                ipv4 udp #{@nat_public_ipv4} 18446744073709551617 192.168.124.10 9000
                EOF
                assert_rejected_without_changes 'Overflowing port'
                sed -i '/18446744073709551617/d' /etc/libvirt/port-forwards.conf
              SH
              run_command_in_vps(node1, @nat_vps_id, <<~SH)
                set -euo pipefail
                printf '%s' \
                  'ipv4 udp #{@nat_public_ipv4} 5354 192.168.124.10 9000' \
                  >>/etc/libvirt/port-forwards.conf
                /etc/libvirt/hooks/network.d/50-port-forwards \
                  dualstack-nat started begin -
                iptables -t nat -S VPSFREE_KVM_DNAT | grep -q -- '--dport 5354'
              SH
              wait_for_udp_echo(
                services,
                node1,
                @nat_vps_id,
                family: 4,
                public_address: @nat_public_ipv4,
                public_port: 5354,
                guest_address: '192.168.124.10',
                guest_port: 9000,
                payload: 'kb-eof',
                timeout: 60
              )
              run_command_in_vps(node1, @nat_vps_id, <<~'SH')
                set -euo pipefail
                sed -i '/^ipv4 udp .* 5354 /d' /etc/libvirt/port-forwards.conf
                /etc/libvirt/hooks/network.d/50-port-forwards \
                  dualstack-nat started begin -
                ! iptables -t nat -S VPSFREE_KVM_DNAT | grep -q -- '--dport 5354'
              SH
            end

            it 'restores forwards across network lifecycle events' do
              configure_nat_udp_forwards(
                node1,
                @nat_vps_id,
                public_ipv4: @nat_public_ipv4,
                public_ipv6: @nat_public_ipv6
              )
              run_command_in_vps(node1, @nat_vps_id, <<~'SH')
                set -euo pipefail
                virsh --connect qemu:///system destroy nat-guest
                virsh --connect qemu:///system net-destroy dualstack-nat
                ! iptables -t nat -S VPSFREE_KVM_DNAT >/dev/null 2>&1
                ! iptables -t filter -S VPSFREE_KVM_FWD >/dev/null 2>&1
                ! ip6tables -t nat -S VPSFREE_KVM_DNAT >/dev/null 2>&1
                ! ip6tables -t filter -S VPSFREE_KVM_FWD >/dev/null 2>&1
                virsh --connect qemu:///system net-start dualstack-nat
                iptables -t nat -S VPSFREE_KVM_DNAT | grep -q -- '--dport 5353'
                iptables -t filter -S VPSFREE_KVM_FWD | grep -q -- '--dport 9000'
                ip6tables -t nat -S VPSFREE_KVM_DNAT | grep -q -- '--dport 5353'
                ip6tables -t filter -S VPSFREE_KVM_FWD | grep -q -- '--dport 9001'
                virsh --connect qemu:///system start nat-guest
              SH
              wait_for_udp_echo(
                services,
                node1,
                @nat_vps_id,
                family: 4,
                public_address: @nat_public_ipv4,
                public_port: 5353,
                guest_address: '192.168.124.10',
                guest_port: 9000,
                payload: 'kb-udp',
                timeout: 180
              )
              wait_for_udp_echo(
                services,
                node1,
                @nat_vps_id,
                family: 6,
                public_address: @nat_public_ipv6,
                public_port: 5353,
                guest_address: 'fd5f:6d2e:9c4a:124::10',
                guest_port: 9001,
                payload: 'kb-udp6',
                timeout: 180
              )
            end

            it 'keeps updates idempotent and removes deleted forwards' do
              run_command_in_vps(node1, @nat_vps_id, <<~'SH')
                set -euo pipefail
                if ! virsh --connect qemu:///system net-list --name \
                    | grep -Fx dualstack-nat >/dev/null; then
                  virsh --connect qemu:///system net-start dualstack-nat
                fi
                if ! virsh --connect qemu:///system domstate nat-guest \
                    | grep -Fx running >/dev/null; then
                  virsh --connect qemu:///system start nat-guest
                fi
              SH
              configure_nat_udp_forwards(
                node1,
                @nat_vps_id,
                public_ipv4: @nat_public_ipv4,
                public_ipv6: @nat_public_ipv6
              )
              2.times do
                run_command_in_vps(
                  node1,
                  @nat_vps_id,
                  '/etc/libvirt/hooks/network.d/50-port-forwards ' \
                  'dualstack-nat started begin -'
                )
              end
              run_command_in_vps(node1, @nat_vps_id, <<~'SH')
                set -euo pipefail
                test "$(iptables -t nat -S PREROUTING | grep -c -- '-j VPSFREE_KVM_DNAT')" -eq 1
                test "$(iptables -t filter -S FORWARD | grep -c -- '-j VPSFREE_KVM_FWD')" -eq 1
                test "$(ip6tables -t nat -S PREROUTING | grep -c -- '-j VPSFREE_KVM_DNAT')" -eq 1
                test "$(ip6tables -t filter -S FORWARD | grep -c -- '-j VPSFREE_KVM_FWD')" -eq 1
                sed -i '/^ipv[46] udp .* 5353 /d' /etc/libvirt/port-forwards.conf
                /etc/libvirt/hooks/network.d/50-port-forwards dualstack-nat started begin -
                ! iptables -t nat -S VPSFREE_KVM_DNAT | grep -q -- '--dport 5353'
                ! ip6tables -t nat -S VPSFREE_KVM_DNAT | grep -q -- '--dport 5353'
              SH
              services.succeeds(
                "test -z \"$(printf kb-udp | nc -u -w 2 #{@nat_public_ipv4} 5353)\""
              )
              services.succeeds(
                "test -z \"$(printf kb-udp6 | " \
                "nc -6 -u -w 2 #{@nat_public_ipv6} 5353)\""
              )
            end
          end

          describe 'public IPv4 and a delegated IPv6 /64 routed through the VPS' do
            it 'keeps delegated addresses off the outer VPS interface' do
              public_ipv4 = @routed_ipv4.fetch('public_ipv4')
              private_ipv4 = @routed_ipv4.fetch('private_ipv4')
              state = services.api_ruby_json(code: <<~RUBY)
                ip = IpAddress.find_by!(ip_addr: #{public_ipv4.inspect})
                puts JSON.generate(
                  route_via_id: ip.route_via_id,
                  network_interface_id: ip.network_interface_id
                )
              RUBY
              expect(state.fetch('route_via_id')).to eq(@routed_ipv4.fetch('route_via_id'))
              expect(state.fetch('network_interface_id')).not_to be_nil
              ipv6_state = services.api_ruby_json(code: <<~RUBY)
                ip = IpAddress.find_by!(ip_addr: '2001:db8:200::', prefix: 64)
                puts JSON.generate(
                  route_via_id: ip.route_via_id,
                  network_interface_id: ip.network_interface_id
                )
              RUBY
              expect(ipv6_state.fetch('route_via_id')).to eq(
                @routed_ipv6.fetch('route_via_id')
              )
              expect(ipv6_state.fetch('network_interface_id')).not_to be_nil
              run_command_in_vps(
                node1,
                @routed_vps_id,
                "! ip -4 address show | grep -F #{Shellwords.escape(public_ipv4)}"
              )
              _, route = node1.succeeds("ip -4 route show #{Shellwords.escape(public_ipv4)}/32")
              expect(route).to include("via #{private_ipv4}")
              expect(route).to include('onlink')
              _, ipv6_route = node1.succeeds(
                "ip -6 route show #{Shellwords.escape(@routed_ipv6.fetch('prefix'))}"
              )
              expect(ipv6_route).to include(
                "via #{@routed_ipv6.fetch('via_ipv6')}"
              )
              run_command_in_vps(
                node1,
                @routed_vps_id,
                "ip -6 address show dev venet0 | " \
                "grep -F #{Shellwords.escape(@routed_ipv6.fetch('via_ipv6'))}; " \
                "! ip -6 address show dev venet0 | " \
                "grep -F #{Shellwords.escape(@routed_ipv6.fetch('ipv6_gateway'))}"
              )
              _, forwarding = run_command_in_vps(
                node1,
                @routed_vps_id,
                'sysctl -n net.ipv4.ip_forward net.ipv6.conf.all.forwarding; ' \
                'cat /etc/sysctl.d/90-libvirt-routing.conf'
              )
              forwarding_lines = forwarding.lines.map(&:strip)
              expect(forwarding_lines.count('1')).to eq(2)
              expect(forwarding_lines).to include(
                'net.ipv4.ip_forward = 1',
                'net.ipv6.conf.all.forwarding = 1'
              )
            end

            it 'refuses stale live routes and applies changed inputs when stopped' do
              changed_ipv4 = '203.0.113.254'
              changed_ipv6_gateway = '2001:db8:ffff:ffff::1'
              environment = {
                'PUBLIC_IPV4' => changed_ipv4,
                'IPV6_GATEWAY' => changed_ipv6_gateway,
                'HOST_TRANSIT_IPV4' => '192.0.2.1',
                'GUEST_TRANSIT_IPV4' => '192.0.2.2'
              }
              encoded = Base64.strict_encode64(configure_routed_network_script)
              command = ['env'] + environment.map { |key, value| "#{key}=#{value}" } +
                        ['bash', '-s']
              probe = machine_probe(
                node1,
                [
                  "printf %s #{Shellwords.escape(encoded)} | base64 -d |",
                  'osctl ct exec',
                  Integer(@routed_vps_id),
                  Shellwords.join(command)
                ].join(' '),
                timeout: 300
              )
              expect(probe.fetch(:status)).not_to eq(0)
              expect(probe.fetch(:output)).to include('public-routed is active')
              _, unchanged_xml = run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system net-dumpxml --inactive public-routed'
              )
              expect(unchanged_xml).to include(
                "address='#{@routed_ipv4.fetch('public_ipv4')}' prefix='32'"
              )
              expect(unchanged_xml).to include(
                "address='#{@routed_ipv6.fetch('ipv6_gateway')}' prefix='64'"
              )
              expect(unchanged_xml).to include("<forward mode='open'/>")
              expect(unchanged_xml).not_to include(changed_ipv4)
              expect(unchanged_xml).not_to include(changed_ipv6_gateway)
              _, original_uuid = run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system net-uuid public-routed'
              )
              original_uuid = original_uuid.strip
              expect(original_uuid).to match(
                /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
              )

              run_command_in_vps(node1, @routed_vps_id, <<~'SH')
                virsh --connect qemu:///system destroy routed-guest
                virsh --connect qemu:///system net-destroy public-routed
              SH
              run_in_vps(
                node1,
                @routed_vps_id,
                configure_routed_network_script,
                environment:
              )
              _, active_xml = run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system net-dumpxml public-routed'
              )
              expect(active_xml).to include("address='#{changed_ipv4}' prefix='32'")
              expect(active_xml).to include(
                "address='#{changed_ipv6_gateway}' prefix='64'"
              )
              expect(active_xml).not_to include(@routed_ipv4.fetch('public_ipv4'))
              expect(active_xml).not_to include(@routed_ipv6.fetch('ipv6_gateway'))
              _, changed_uuid = run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system net-uuid public-routed'
              )
              expect(changed_uuid.strip).to eq(original_uuid)

              run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system net-destroy public-routed'
              )
              run_in_vps(
                node1,
                @routed_vps_id,
                configure_routed_network_script,
                environment: environment.merge(
                  'PUBLIC_IPV4' => @routed_ipv4.fetch('public_ipv4'),
                  'IPV6_GATEWAY' => @routed_ipv6.fetch('ipv6_gateway')
                )
              )
              _, restored_xml = run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system net-dumpxml public-routed'
              )
              expect(restored_xml).to include(
                "address='#{@routed_ipv4.fetch('public_ipv4')}' prefix='32'"
              )
              expect(restored_xml).to include(
                "address='#{@routed_ipv6.fetch('ipv6_gateway')}' prefix='64'"
              )
              _, restored_uuid = run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system net-uuid public-routed'
              )
              expect(restored_uuid.strip).to eq(original_uuid)
              run_command_in_vps(
                node1,
                @routed_vps_id,
                'virsh --connect qemu:///system start routed-guest'
              )
            end

            it 'routes IPv4 HTTP, SSH and the guest source address without NAT' do
              public_ipv4 = @routed_ipv4.fetch('public_ipv4')
              wait_for_guest_command(
                services,
                node1,
                @routed_vps_id,
                'routed-guest',
                "curl --fail --silent http://#{public_ipv4}/ | grep -Fx routed",
                timeout: 180
              )
              services.succeeds(
                "ssh-keyscan -T 5 #{public_ipv4} 2>/dev/null | grep -F #{public_ipv4}"
              )
              wait_for_guest_command(
                services,
                node1,
                @routed_vps_id,
                'routed-guest',
                "curl --fail --silent http://#{public_ipv4}/outbound4 " \
                "| grep -Fx #{public_ipv4}",
                timeout: 180
              )
            end

            it 'routes the delegated IPv6 /64 without NAT' do
              guest_ipv6 = @routed_ipv6.fetch('guest_ipv6')
              ipv6_gateway = @routed_ipv6.fetch('ipv6_gateway')
              run_command_in_vps(
                node1,
                @routed_vps_id,
                "ip -6 address show dev virbr-public | " \
                "grep -F #{Shellwords.escape(ipv6_gateway)}; " \
                "! ip -6 address show dev venet0 | " \
                "grep -F #{Shellwords.escape(ipv6_gateway)}"
              )
              _, route = run_command_in_vps(
                node1,
                @routed_vps_id,
                "ip -6 route show #{Shellwords.escape(@routed_ipv6.fetch('prefix'))}"
              )
              expect(route).to include('dev virbr-public')
              wait_for_guest_command(
                services,
                node1,
                @routed_vps_id,
                'routed-guest',
                "curl --globoff --fail --silent http://[#{guest_ipv6}]/ | grep -Fx routed",
                timeout: 180
              )
              services.succeeds(
                "ssh-keyscan -6 -T 5 #{guest_ipv6} 2>/dev/null | grep -F #{guest_ipv6}"
              )
              wait_for_guest_command(
                services,
                node1,
                @routed_vps_id,
                'routed-guest',
                "curl --globoff --fail --silent http://[#{guest_ipv6}]/outbound6 " \
                "| grep -Fx #{guest_ipv6}",
                timeout: 180
              )
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
              public_ipv4 = documentation_vps_public_ipv4(services, @vps_id)
              _, route = run_command_in_vps(
                node1,
                @vps_id,
                'ip -4 route get 172.16.106.53'
              )
              expect(route).to include("src #{public_ipv4}")
            end

            it 'does not start QEMU on an NFSv3 server without NLM' do
              _, output = run_nfs_command_in_vps(services, node1, @vps_id, <<~'SH')
                set -euo pipefail
                mkdir -p /mnt/installer-iso
                mount -t nfs -o ro,vers=3 172.16.106.53:/srv/kb-installer /mnt/installer-iso
                pidfile=/tmp/kb-qemu-normal.pid
                output_file=/tmp/kb-qemu-normal.output
                cleanup() {
                  local pid=
                  if [[ -s "$pidfile" ]]; then
                    pid=$(cat "$pidfile")
                    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                      kill "$pid" 2>/dev/null || true
                      for _ in {1..50}; do
                        ! kill -0 "$pid" 2>/dev/null && break
                        sleep 0.1
                      done
                      if kill -0 "$pid" 2>/dev/null; then
                        kill -KILL "$pid" 2>/dev/null || true
                        for _ in {1..50}; do
                          ! kill -0 "$pid" 2>/dev/null && break
                          sleep 0.1
                        done
                      fi
                    fi
                  fi
                  rm -f "$pidfile" "$output_file"
                  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    printf 'QEMU process %s survived TERM and KILL\n' "$pid" >&2
                    return 1
                  fi
                  umount /mnt/installer-iso
                }
                finish() {
                  local status=$?
                  cleanup || status=1
                  trap - EXIT
                  exit "$status"
                }
                trap finish EXIT
                rm -f "$pidfile" "$output_file"
                set +e
                LC_ALL=C timeout --verbose --kill-after=5 20 qemu-system-x86_64 \
                  -nodefaults -display none -S -daemonize \
                  -drive file=/mnt/installer-iso/installer.iso,media=cdrom,readonly=on \
                  -pidfile "$pidfile" >"$output_file" 2>&1
                status=$?
                set -e
                output=$(<"$output_file")
                printf '%s\n' "$output"

                case "$status" in
                  0)
                    printf 'QEMU unexpectedly started without NLM\n' >&2
                    exit 1
                    ;;
                  124|137)
                    grep -Fq 'timeout: sending signal TERM to command' <<<"$output"
                    printf 'QEMU timed out while waiting for an NFS lock\n'
                    ;;
                  *)
                    grep -Eiq \
                      'failed to (get .*lock|lock byte)|resource temporarily unavailable' \
                      <<<"$output"
                    ;;
                esac
              SH
              expect(output).to match(/lock|temporarily unavailable|timed out/i)
            end

            it 'uses nolock only for the same read-only installer ISO' do
              _, output = run_in_vps(
                node1,
                @vps_id,
                mount_readonly_iso_script,
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
            Mount_Path_Pseudo = true;
            Plugins_Dir = "${pkgs.nfs-ganesha}/lib/ganesha";
          }

          EXPORT {
            Export_Id = 1;
            Path = /srv/kb-installer;
            Pseudo = /srv/kb-installer;
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
          {
            address = "10.106.0.0";
            prefixLength = 24;
            via = "172.16.106.41";
          }
        ];
        services.dbus.packages = [ pkgs.nfs-ganesha ];
        services.rpcbind.enable = true;
        services.nginx.virtualHosts."kb-kvm-upstream" = {
          default = true;
          listen = [
            {
              addr = "0.0.0.0";
              port = 18080;
            }
            {
              addr = "[::]";
              port = 18080;
            }
          ];
          locations."/assets/".alias = "${guestAssets}/";
          locations."= /source".extraConfig = ''
            default_type text/plain;
            return 200 "$remote_addr\n";
          '';
        };
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
        environment.systemPackages =
          (with pkgs; [
            curl
            netcat-openbsd
            nfs-utils
            nfs-ganesha
          ])
          ++ [ guestAppliance.udpEcho ];
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
    seedPools = false;
    testName = "kb-kvm";
    testDescription = ''
      Validate the vpsFree KVM documentation against a vpsAdmin-provisioned
      Debian container host on the capture cluster topology.
    '';
    testScripts = scripts;
    extraModules = {
      services = nfsServicesModule;
    };
  }) { inherit pkgs; }
)
