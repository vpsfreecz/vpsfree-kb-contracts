import ../../make-test.nix (
  {
    pkgs,
    lib,
    kbStandalone ? null,
    ...
  }:
  let
    profile = if kbStandalone == null then
      throw "KB standalone tests require --test-config from the exact clean Git-flake standalone-test-config output"
    else kbStandalone;
    quote = value: "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";
    common = ''
      require 'json'
      require 'shellwords'

      ENGINE = 'vpsfree-kb-devcluster'
      SOURCE = ${quote (toString profile.source)}
      EXPECTED_SOURCE = JSON.parse(File.read(${quote (toString profile.sourceMetadata)}))

      def run(command, timeout: 900)
        machine.succeeds("env -u DEV_SESSION_SLUG -u DEV_SESSION_WORKSPACE -u DEVCLUSTER_WORKSPACE " \
          "sh -c #{Shellwords.escape("cd /tmp/kb-ordinary && #{command}")}", timeout:).last
      end

      def configuration(name, topology, port)
        script = <<~RUBY
          require 'json'
          config = JSON.parse(File.read('#{SOURCE}/cluster/default-config.json'))
          config['dns']['enable'] = false if config['dns']
          config['resolver'] = { 'mode' => 'cluster', 'upstreamNameservers' => ['10.0.2.3'] }
          %w[domains tmpDomains].each do |group|
            config.fetch(group).each_key { |key| config[group][key] = "#{key.downcase}-#{group.downcase}.example.test" }
          end
          machines = ['services', *config.fetch('topologies').fetch('#{topology}')]
          config['local'] = {
            'bindAddress' => '127.0.0.1', 'multicastPort' => #{port + 20},
            'ports' => machines.each_with_index.to_h { |entry, index| [entry, { 'ssh' => #{port} + index }] }
          }
          config['local']['ports']['services']['https'] = #{port + 10}
          File.write('/tmp/kb-ordinary/#{name}.json', JSON.generate(config))
        RUBY
        machine.succeeds("ruby -e #{Shellwords.escape(script)}")
        "/tmp/kb-ordinary/#{name}.json"
      end

      def require_nested_capacity(memory_kib, shm_kib)
        machine.succeeds('test -r /dev/kvm && test -w /dev/kvm')
        # KVM_GET_API_VERSION proves that the outer guest can actually open KVM.
        machine.succeeds("ruby -e 'f=File.open(\"/dev/kvm\", \"r+\"); abort unless f.ioctl(0xAE00)==12'")
        available = machine.succeeds("awk '/^MemAvailable:/ { print $2 }' /proc/meminfo").last.strip.to_i
        shared = machine.succeeds("df -Pk /dev/shm | awk 'NR==2 { print $4 }'").last.strip.to_i
        expect(available).to be >= memory_kib
        expect(shared).to be >= shm_kib
      end

      def expect_initial_source(descriptor)
        expect(descriptor.fetch('provenance').fetch('source')).to eq(EXPECTED_SOURCE)
        descriptor.fetch('provenance').fetch('machine_toplevels').each do |name, closure|
          expect(run("#{ENGINE} --state-root #{@cluster_root} ssh #{@cluster_slug} #{name} -- readlink -f /run/current-system").strip).to eq(closure)
        end
      end

      before(:all) do
        machine.start
        machine.wait_for_boot
        machine.succeeds('mkdir -m 700 /tmp/kb-ordinary')
        free_kib = machine.succeeds("df -Pk /tmp/kb-ordinary | awk 'NR==2 { print $4 }'").last.strip.to_i
        expect(free_kib).to be >= 96 * 1024 * 1024
        machine.succeeds('test ! -e /tmp/kb-ordinary/work && ! command -v dev-session && ! command -v workspace-host')
      end
    '';
  in
  {
    name = "kb-runtime-standalone";
    description = "Installed standalone KB tools without workspace runtime or session state";
    machine = {
      spin = "nixos";
      memory = 32768;
      cpus = 8;
      diskSize = 131072;
      config = {
        environment.systemPackages = [ profile.runtimePackage profile.capturePackage pkgs.ruby pkgs.git pkgs.jq ];
        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        nix.settings.extra-substituters = [ "https://cache.vpsadminos.org" ];
        nix.settings.extra-trusted-public-keys = [ "cache.vpsadminos.org:wpIJlNZQIhS+0gFf1U3MC9sLZdLW3sh5qakOWGDoDrE=" ];
        boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
        boot.extraModprobeConfig = ''
          options kvm_intel nested=1
          options kvm_amd nested=1
        '';
        fileSystems."/dev/shm".options = [ "size=24G" ];
      };
    };
    testScripts = {
      installed-layout = {
        tags = [ "kb-runtime-launcher" ];
        description = "Package defaults, read-only source and writable artifact layout";
        script = common + ''
          describe 'installed standalone entrypoints' do
            it 'does not need session discovery and never writes to its store source' do
              before = machine.succeeds("sha256sum #{SOURCE}/captures.json #{SOURCE}/flake.lock")
              result = JSON.parse(run("#{ENGINE} status nonexistent --json"))
              expect(result.fetch('found')).to be(false)
              machine.succeeds('test ! -e /tmp/kb-ordinary/.devcluster')
              run('vpsfree-kb-capture --help')
              # Invalid dedicated descriptor fails after choosing writable CWD
              # artifacts and before any remote/fixture call.
              machine.fails("cd /tmp/kb-ordinary && vpsfree-kb-capture --connection /tmp/absent-connection --language en")
              machine.succeeds('test -d /tmp/kb-ordinary/tmp')
              machine.succeeds('mkdir -m 700 /tmp/kb-explicit-output')
              machine.fails("cd /tmp/kb-ordinary && vpsfree-kb-capture --connection /tmp/absent-connection --language cs --output-root /tmp/kb-explicit-output")
              machine.succeeds('test -d /tmp/kb-explicit-output/tmp')
              expect(machine.succeeds("sha256sum #{SOURCE}/captures.json #{SOURCE}/flake.lock")).to eq(before)
            end
          end
        '';
      };
      two-instances = {
        tags = [ "kb-runtime-launcher" "nested-kvm" ];
        description = "Two real minimal clusters with the same slug and disjoint explicit local resources";
        script = common + ''
          describe 'real standalone isolation' do
            it 'keeps independently owned processes, disks, sockets, ports and reset state' do
              require_nested_capacity(20 * 1024 * 1024, 18 * 1024 * 1024)
              first = configuration('first', 'single', 24000)
              second = configuration('second', 'single', 24100)
              root_a = '/tmp/kb-ordinary/first-state'
              root_b = '/tmp/kb-ordinary/second-state'
              begin
                run("#{ENGINE} --state-root #{root_a} start shared-slug --network local --config #{first}")
                run("#{ENGINE} --state-root #{root_b} start shared-slug --network local --config #{second}")
                descriptors = [root_a, root_b].map { |root| JSON.parse(run("#{ENGINE} --state-root #{root} connection shared-slug")) }
                [root_a, root_b].zip(descriptors).each do |root, descriptor|
                  @cluster_root, @cluster_slug = root, 'shared-slug'
                  expect_initial_source(descriptor)
                end
                expect(descriptors[0].fetch('instance_id')).not_to eq(descriptors[1].fetch('instance_id'))
                expect(descriptors[0].fetch('machines')).not_to eq(descriptors[1].fetch('machines'))
                run("#{ENGINE} --state-root #{root_a} stop shared-slug")
                run("#{ENGINE} --state-root #{root_a} reset shared-slug")
                expect(JSON.parse(run("#{ENGINE} --state-root #{root_b} status shared-slug --json")).fetch('ready')).to be(true)
                run("#{ENGINE} --state-root #{root_b} ssh shared-slug services -- test -e /etc/vpsfree-kb-capture.json")
              ensure
                [root_a, root_b].each do |root|
                  machine.succeeds("if test -f #{root}/clusters/shared-slug/phase.json; then #{ENGINE} --state-root #{root} stop shared-slug; fi", timeout: 300)
                end
              end
            end
          end
        '';
      };
      resume-update = {
        tags = [ "kb-runtime-launcher" "nested-kvm" ];
        description = "Cold resume and exact changed-source preparation preserve owned root and data disks";
        script = common + ''
          describe 'prepared boot artifacts' do
            it 'resumes without rebuild and imports a genuine committed candidate through the old guest' do
              require_nested_capacity(12 * 1024 * 1024, 10 * 1024 * 1024)
              config = configuration('update', 'single', 24300)
              root = '/tmp/kb-ordinary/update-state'
              slug = 'update-test'
              prefix = "#{ENGINE} --state-root #{root}"
              begin
                run("#{prefix} start #{slug} --network local --config #{config}")
                old = JSON.parse(run("#{prefix} connection #{slug}"))
                @cluster_root, @cluster_slug = root, slug
                expect_initial_source(old)
                run("#{prefix} ssh #{slug} services -- sh -c 'printf root-sentinel > /root/kb-root-sentinel'")
                run("#{prefix} ssh #{slug} node1 -- sh -c 'printf data-sentinel > /tank/kb-data-sentinel'")
                credential_paths = %w[id_ed25519 id_ed25519.pub vpsadmin-ca.crt vpsadmin-ca.key vpsadmin-cert.crt vpsadmin-cert.key].map { |name| "#{root}/clusters/#{slug}/credentials/#{name}" }
                credentials = run("sha256sum #{credential_paths.join(' ')}")
                disk_inodes = run("stat -c '%n %i %s' #{root}/clusters/#{slug}/disks/services-root.img #{root}/clusters/#{slug}/disks/node1-tank.img")
                run("#{prefix} stop #{slug}")
                run("#{prefix} resume #{slug}")
                resumed = JSON.parse(run("#{prefix} connection #{slug}"))
                expect(resumed.fetch('run_id')).not_to eq(old.fetch('run_id'))
                expect(resumed.fetch('artifact_id')).to eq(old.fetch('artifact_id'))
                expect(resumed.fetch('artifact_sha256')).to eq(old.fetch('artifact_sha256'))
                expect(resumed.fetch('provenance').fetch('machine_toplevels')).to eq(old.fetch('provenance').fetch('machine_toplevels'))
                expect_initial_source(resumed)
                expect(run("sha256sum #{credential_paths.join(' ')}")).to eq(credentials)
                expect(run("stat -c '%n %i %s' #{root}/clusters/#{slug}/disks/services-root.img #{root}/clusters/#{slug}/disks/node1-tank.img")).to eq(disk_inodes)
                expect(run("#{prefix} ssh #{slug} services -- cat /root/kb-root-sentinel").strip).to eq('root-sentinel')
                expect(run("#{prefix} ssh #{slug} node1 -- cat /tank/kb-data-sentinel").strip).to eq('data-sentinel')

                # Construct an actual committed immutable K fixture, with the
                # same lock and runtime code and a distinct source identity.
                run("cp -a #{SOURCE} /tmp/kb-ordinary/candidate && chmod -R u+w /tmp/kb-ordinary/candidate")
                run("printf 'isolated update source fixture\\n' > candidate/runtime-source-fixture.txt")
                run("printf 'runtime: create isolated source fixture\\n' > candidate-commit.message")
                run("git -C candidate init -b source-test && git -C candidate add -- . && git -C candidate -c user.name=KB-test -c user.email=kb@example.test commit -F /tmp/kb-ordinary/candidate-commit.message")
                run("umask 077; ruby candidate/cluster/source-metadata.rb --checkout /tmp/kb-ordinary/candidate > /tmp/kb-ordinary/candidate-source.json")
                candidate = JSON.parse(run('cat candidate-source.json'))
                expect(candidate.fetch('revision')).not_to eq(old.fetch('provenance').fetch('source').fetch('revision'))
                expect(candidate.fetch('lock_sha256')).to eq(old.fetch('provenance').fetch('source').fetch('lock_sha256'))
                run("#{prefix} --software-metadata /tmp/kb-ordinary/candidate-source.json update #{slug} --network local --config #{config}", timeout: 1800)
                current = JSON.parse(run("#{prefix} connection #{slug}"))
                expect(current.fetch('run_id')).not_to eq(resumed.fetch('run_id'))
                expect(current.fetch('artifact_id')).not_to eq(resumed.fetch('artifact_id'))
                expect(current.fetch('provenance').fetch('source')).to eq(candidate)
                expect(current.fetch('provenance').fetch('machine_toplevels')).not_to eq(resumed.fetch('provenance').fetch('machine_toplevels'))
                expect(run("#{prefix} ssh #{slug} services -- cat /root/kb-root-sentinel").strip).to eq('root-sentinel')
                expect(run("#{prefix} ssh #{slug} node1 -- cat /tank/kb-data-sentinel").strip).to eq('data-sentinel')
                expect(run("stat -c '%n %i %s' #{root}/clusters/#{slug}/disks/services-root.img #{root}/clusters/#{slug}/disks/node1-tank.img")).to eq(disk_inodes)
                expect(run("sha256sum #{credential_paths.join(' ')}")).to eq(credentials)
                current.fetch('provenance').fetch('machine_toplevels').each do |name, closure|
                  expect(run("#{prefix} ssh #{slug} #{name} -- readlink -f /run/current-system").strip).to eq(closure)
                end
              ensure
                machine.succeeds("if test -f #{root}/clusters/#{slug}/phase.json; then #{prefix} stop #{slug}; fi", timeout: 300)
              end
            end
          end
        '';
      };
      bilingual-capture = {
        tags = [ "kb-runtime-launcher" "nested-kvm" "kb-capture" ];
        description = "Installed matching source capture and validation with full screenshot fixture topology";
        script = common + ''
          describe 'standalone bilingual checkpoint' do
            it 'retains Czech and English artifacts and validates the full source inventory' do
              require_nested_capacity(22 * 1024 * 1024, 20 * 1024 * 1024)
              config = configuration('screenshots', 'screenshots', 24200)
              root = '/tmp/kb-ordinary/capture-state'
              output = '/tmp/kb-capture-evidence'
              machine.succeeds("mkdir -m 700 #{output}")
              begin
                run("#{ENGINE} --state-root #{root} start screenshots --network local --topology screenshots --config #{config}")
                @cluster_root, @cluster_slug = root, 'screenshots'
                expect_initial_source(JSON.parse(run("#{ENGINE} --state-root #{root} connection screenshots")))
                %w[cs en].each do |language|
                  run("vpsfree-kb-capture --state-root #{root} --cluster screenshots --language #{language} --checkpoint networking/ip-address-list --output-root #{output}", timeout: 1800)
                end
                run("vpsfree-kb-validate --output-root #{output} --update")
                run("vpsfree-kb-validate --output-root #{output}")
                rows = JSON.parse(run("cat #{output}/tmp/capture-results.json"))
                expect(rows.map { |row| [row.fetch('language'), row.fetch('id')] }.sort).to eq([
                  ['cs', 'networking/ip-address-list'], ['en', 'networking/ip-address-list']
                ])
              ensure
                machine.succeeds("if test -f #{root}/clusters/screenshots/phase.json; then #{ENGINE} --state-root #{root} stop screenshots; fi", timeout: 300)
              end
            end
          end
        '';
      };
    };
  }
)
