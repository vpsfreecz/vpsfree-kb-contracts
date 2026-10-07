# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../cluster/lib/kb_runtime'

class RuntimeTest < Minitest::Test
  def test_empty_private_lock_file_is_valid_but_nonempty_zero_limit_file_is_rejected
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      lock_path = File.join(state.root, 'locks', 'example.gate.lock')
      state.lock('gate', create: true) do
        assert_equal('', state.file(lock_path, limit: 0))
        assert_equal(0o600, File.stat(lock_path).mode & 0o777)
        assert_raises(KbRuntime::Error) { state.read(lock_path, limit: 0) }
      end
      File.write(lock_path, 'unexpected')
      assert_raises(KbRuntime::Error) { state.file(lock_path, limit: 0) }
      assert_raises(KbRuntime::Error) { state.lock('gate') { flunk('invalid lock was acquired') } }
      assert_equal('unexpected', File.read(lock_path), 'validation must not truncate the invalid lock')
    end
  end

  def test_inherited_source_overrides_do_not_reach_the_build_subprocess
    name = 'VPSADMIN_DEVCLUSTER_VPSADMIN_SOURCE'
    original = ENV[name]
    ENV[name] = '/a/conflicting/source'
    state = Struct.new(:slug).new('source-proof')
    environment = KbRuntime::Software.build_environment(state, { 'topology' => 'single', 'network' => 'local',
      'run_id' => 'run', 'instance_id' => 'instance' }, '/config', '/credentials', '/identity')
    output, _error, status = Open3.capture3(environment, RbConfig.ruby, '-e',
      'require "json"; puts JSON.generate(ENV.select { |k, _| k.start_with?("VPSADMIN_") })')
    assert(status.success?)
    child_environment = JSON.parse(output)
    refute(child_environment.key?(name))
    assert_equal('/config', child_environment.fetch('VPSADMIN_DEVCLUSTER_CONFIG_FILE'))
    assert_equal('instance', child_environment.fetch('VPSADMIN_KB_INSTANCE_ID'))
    assert_equal('0', child_environment.fetch('VPSADMIN_DEVCLUSTER_TELEGRAM_ENABLE'))
  ensure
    ENV[name] = original
  end

  def test_actual_nested_follows_keeps_the_remaining_nixpkgs_component
    lock = JSON.parse(File.read(File.expand_path('../flake.lock', __dir__)))
    nodes = lock.fetch('nodes')
    vpsadmin = nodes.fetch('root').fetch('inputs').fetch('vpsadmin')
    os = nodes.fetch(vpsadmin).fetch('inputs').fetch('vpsadminos')
    nixpkgs = nodes.fetch(os).fetch('inputs').fetch('nixpkgs')
    assert_equal(nodes.fetch(nixpkgs).fetch('locked').slice('rev', 'narHash'), KbRuntime::Software.locked_inputs(lock).fetch('nixpkgs'))
    refute_equal(KbRuntime::Software.locked_inputs(lock).fetch('vpsadminos'), KbRuntime::Software.locked_inputs(lock).fetch('nixpkgs'))
  end

  def test_same_slug_under_two_roots_has_independent_identity_and_runtime_namespace
    Dir.mktmpdir do |directory|
      first = KbRuntime::State.new(File.join(directory, 'first'), 'same-slug')
      second = KbRuntime::State.new(File.join(directory, 'second'), 'same-slug')
      identities = [first, second].map { |state| state.transaction(create: true) { state.initialize_identity } }
      refute_equal(identities[0]['instance_id'], identities[1]['instance_id'])
      resources = [first, second].map { |state| KbRuntime::Resources.new(state, root: File.join(directory, 'runtime', 'reservations')) }
      paths = resources.each_with_index.map { |value, index| value.socket_dir(identities[index]['instance_id'], '00000000-0000-0000-0000-000000000001') }
      refute_equal(*paths)
      FileUtils.cp(first.path('identity.json'), second.path('identity.json'))
      assert_raises(KbRuntime::Error) { second.identity }
    end
  end

  def test_legacy_or_symlink_state_is_not_adopted_or_removed
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      state.transaction(create: true) { state.initialize_identity }
      identity = File.binread(state.path('identity.json'))
      File.unlink(state.path('identity.json'))
      assert_raises(Errno::ENOENT) { state.identity }
      assert(File.directory?(state.directory))
      File.write(state.path('identity.json'), identity)
      File.chmod(0o600, state.path('identity.json'))
      File.symlink(state.root, File.join(directory, 'alias'))
      assert_raises(KbRuntime::Error) { KbRuntime::State.new(File.join(directory, 'alias'), 'example') }
    end
  end

  def test_resource_conflict_is_atomic_and_requires_positive_exit_proof_to_release
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      state.transaction(create: true) { state.initialize_identity }
      resources = KbRuntime::Resources.new(state, root: File.join(directory, 'claims'))
      identity = state.identity
      record = identity.merge('run_id' => SecureRandom.uuid, 'boot_id' => KbRuntime::ProcessIdentity.boot_id,
                              'resource_claims' => [{ 'kind' => 'udp', 'host' => '0.0.0.0', 'port' => free_udp_port }])
      resources.claim(record)
      before = Dir.glob(File.join(resources.root, '*.json')).map { |file| File.binread(file) }
      assert_raises(KbRuntime::Error) { resources.claim(record.merge('run_id' => SecureRandom.uuid)) }
      assert_equal(before, Dir.glob(File.join(resources.root, '*.json')).map { |file| File.binread(file) })
      assert_raises(KbRuntime::Error) { resources.release(record, processes_gone: false) }
      resources.release(record, processes_gone: true)
      assert_empty(Dir.glob(File.join(resources.root, '*.json')))
    end
  end

  def test_udp_is_claimed_by_actual_port_across_different_names_and_roots
    Dir.mktmpdir do |directory|
      states = %w[first second].map { |name| KbRuntime::State.new(File.join(directory, name), name) }
      identities = states.map { |state| state.transaction(create: true) { state.initialize_identity } }
      resources = states.map { |state| KbRuntime::Resources.new(state, root: File.join(directory, 'claims')) }
      port = free_udp_port
      records = identities.map do |identity|
        identity.merge('run_id' => SecureRandom.uuid, 'boot_id' => KbRuntime::ProcessIdentity.boot_id,
          'resource_claims' => [{ 'kind' => 'udp', 'host' => '0.0.0.0', 'port' => port }])
      end
      resources.first.claim(records.first)
      before = Dir.glob(File.join(resources.first.root, '*.json')).to_h { |path| [path, File.binread(path)] }
      assert_raises(KbRuntime::Error) { resources.last.claim(records.last) }
      assert_equal(before, Dir.glob(File.join(resources.first.root, '*.json')).to_h { |path| [path, File.binread(path)] })
      assert_raises(KbRuntime::Error) { resources.first.release(records.first, processes_gone: false) }
      resources.first.release(records.first, processes_gone: true)
      resources.last.claim(records.last)
      resources.last.release(records.last, processes_gone: true)
    end
  end

  def test_foreign_udp_listener_refuses_the_whole_claim_without_reuse_or_cleanup
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      state.transaction(create: true) { state.initialize_identity }
      resources = KbRuntime::Resources.new(state, root: File.join(directory, 'claims'))
      listener = UDPSocket.new
      listener.bind('0.0.0.0', 0)
      port = listener.addr[1]
      record = state.identity.merge('run_id' => SecureRandom.uuid, 'boot_id' => KbRuntime::ProcessIdentity.boot_id,
        'resource_claims' => [{ 'kind' => 'udp', 'host' => '0.0.0.0', 'port' => port }])
      assert_raises(KbRuntime::Error) { resources.claim(record) }
      assert_empty(Dir.glob(File.join(resources.root, '*.json')))
      assert_equal(port, listener.addr[1])
      refute(listener.closed?)
    ensure
      listener&.close
    end
  end

  def test_tcp_and_udp_port_numbers_are_distinct_resources
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      state.transaction(create: true) { state.initialize_identity }
      resources = KbRuntime::Resources.new(state, root: File.join(directory, 'claims'))
      port = free_udp_port
      record = state.identity.merge('run_id' => SecureRandom.uuid, 'boot_id' => KbRuntime::ProcessIdentity.boot_id,
        'resource_claims' => [{ 'kind' => 'udp', 'host' => '0.0.0.0', 'port' => port },
          { 'kind' => 'tcp', 'host' => '127.0.0.1', 'port' => port }].sort_by { |claim| JSON.generate(claim) })
      refute(resources.conflicting?(*record.fetch('resource_claims')))
      resources.claim(record)
      assert_equal(1, Dir.glob(File.join(resources.root, '*.json')).size)
      resources.release(record, processes_gone: true)
    end
  end

  def free_udp_port
    socket = UDPSocket.new
    socket.bind('0.0.0.0', 0)
    socket.addr[1]
  ensure
    socket&.close
  end

  def test_retained_ssh_trust_accepts_the_same_endpoint_and_key_but_refuses_rebinding
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'trust')
      state.transaction(create: true) { state.initialize_identity }
      state.private_directory(state.path('credentials'), create: true)
      known = File.join(state.path('credentials'), 'known_hosts')
      File.write(known, '', mode: 'wb', perm: 0o600)
      engine = KbRuntime::Engine.new(state:, software: nil, controller: [])
      endpoint = { 'host' => '127.0.0.1', 'port' => 10_022 }
      key = 'AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC'
      scan = lambda do |command, *args|
        assert_equal('ssh-keyscan', command)
        assert_equal(%w[-T 5 -p], args.take(3))
        "[#{args.last}]:#{args[3]} ssh-ed25519 #{key}"
      end
      KbRuntime::Software.stub(:command, scan) do
        record = { 'endpoints' => { 'services' => endpoint } }
        engine.establish_ssh_trust(record)
        retained = File.binread(known)
        engine.establish_ssh_trust(record)
        assert_equal(retained, File.binread(known))
        [endpoint.merge('port' => 20_022), endpoint.merge('host' => '127.0.0.2')].each do |changed|
          assert_raises(KbRuntime::Error) { engine.establish_ssh_trust('endpoints' => { 'services' => changed }) }
          assert_equal(retained, File.binread(known))
        end
        key = 'a-different-guest-key'
        assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record) }
        assert_equal(retained, File.binread(known))
      end
    end
  end

  def test_capture_gate_makes_status_busy_without_mutating_receipts
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      state.transaction(create: true) { state.initialize_identity }
      engine = KbRuntime::Engine.new(state:, software: nil, controller: [])
      before = File.binread(state.path('identity.json'))
      state.lock('gate') { assert_raises(KbRuntime::Busy) { engine.status } }
      assert_equal(before, File.binread(state.path('identity.json')))
    end
  end

  def test_a_reused_or_foreign_pid_is_neither_live_nor_signal_authority
    record = KbRuntime::ProcessIdentity.read(Process.pid)
    assert(KbRuntime::ProcessIdentity.matches?(record))
    refute(KbRuntime::ProcessIdentity.matches?(record.merge('start_ticks' => record['start_ticks'] + 1)))
    refute(KbRuntime::ProcessIdentity.gone?(record.merge('boot_id' => SecureRandom.uuid)))
    assert(KbRuntime::ProcessIdentity.matches?(record))
  end
end

class FakeSoftware
  attr_reader :metadata, :builds

  def initialize
    @metadata = { 'schema' => 1, 'revision' => 'a' * 40 }
    @builds = 0
  end

  def prepare(state, identity, config, topology:, network:, credentials:)
    id = SecureRandom.uuid
    input = state.path("input-#{id}.json")
    state.write(input, config, immutable: true)
    inputs = { 'config' => config, 'topology' => topology, 'network' => network }
    digest = Digest::SHA256.hexdigest(KbRuntime::Software.canonical_json(inputs))
    { 'schema' => 1, 'instance_id' => identity['instance_id'], 'artifact_id' => id,
      'source' => metadata.dup, 'topology' => topology, 'network' => network, 'input_path' => input,
      'config_input_sha256' => digest, 'build_inputs' => inputs,
      'guest_identity' => { 'schema' => 1, 'instance_id' => identity['instance_id'], 'artifact_id' => id,
        'config_input_sha256' => digest, 'source' => metadata.dup },
      'layout' => { 'services' => { 'spin' => 'nixos', 'root_image' => true, 'disks' => [] } },
      'credential_identity' => KbRuntime::Software.credentials_identity(credentials) }
  end

  def build(_state, candidate, _credentials)
    @builds += 1
    entrypoint = File.expand_path('fixtures/fake-kb-runner.rb', __dir__)
    candidate.merge('build_inputs' => candidate['build_inputs'].reject { |key, _value| key == 'config' },
      'config_path' => candidate['input_path'], 'config_sha256' => Digest::SHA256.file(candidate['input_path']).hexdigest,
      'runner' => entrypoint, 'runner_identity' => { 'executable' => RbConfig.ruby, 'entrypoint' => entrypoint },
      'machine_toplevels' => { 'services' => "/nix/store/#{'0' * 32}-synthetic-system" })
  end
end

# This transport substitutes the VM/certificate boundary only. Reservation,
# runner supervision, control peer identity, gates and cleanup remain real.
class LocalTransportEngine < KbRuntime::Engine
  attr_accessor :preparation_failure

  def initialize_credentials(_config)
    state.private_directory(state.path('credentials'), create: true)
    %w[id_ed25519 id_ed25519.pub known_hosts vpsadmin-ca.crt vpsadmin-ca.key vpsadmin-cert.crt vpsadmin-cert.key].each do |name|
      path = File.join(state.path('credentials'), name)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write('synthetic credential') } unless File.exist?(path)
    end
    state.path('credentials')
  end

  def establish_ssh_trust(_record); end
  def verify_live(record)
    raise KbRuntime::Error, 'fake runner is not live' unless live?(record)
    true
  end
  def refresh(_record = launch); end

  private

  def prepare_closures(old, value)
    verify_live(old)
    raise KbRuntime::Error, preparation_failure if preparation_failure
    value.fetch('machine_toplevels').each do |machine, system|
      state.write(state.path("prepared-#{value['artifact_id']}-#{machine}.json"),
        { 'complete' => true, 'instance_id' => value['instance_id'], 'artifact_id' => value['artifact_id'],
        'artifact_sha256' => artifact_digest(value), 'machine' => machine, 'toplevel' => system })
    end
    state.write(state.path("prepared-#{value['artifact_id']}.json"),
      { 'complete' => true, 'instance_id' => value['instance_id'], 'artifact_id' => value['artifact_id'], 'kind' => 'import', 'layout' => value['layout'] })
  end
end

class RuntimeLifecycleTest < Minitest::Test
  def config
    { 'topologies' => { 'single' => [] }, 'services' => {}, 'nodes' => {},
      'local' => { 'bindAddress' => '127.0.0.1', 'multicastPort' => free_udp_port, 'ports' => { 'services' => { 'ssh' => free_port, 'https' => free_port } } },
      'domains' => { 'api' => 'api.example.test', 'webui' => 'webui.example.test', 'console' => 'console.example.test' },
      'seed' => { 'users' => [] } }
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def free_udp_port
    socket = UDPSocket.new
    socket.bind('0.0.0.0', 0)
    socket.addr[1]
  ensure
    socket&.close
  end

  def test_local_multicast_requires_an_explicit_integer_but_bridge_does_not
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      identity = value.state.transaction(create: true) { value.state.initialize_identity }
      [nil, '10000', 0, 65_536, 10.5].each do |port|
        candidate = config
        candidate['local']['multicastPort'] = port
        assert_raises(KbRuntime::Error) { value.requested(candidate, 'single', 'local', identity, SecureRandom.uuid) }
      end
      candidate = config
      candidate.delete('local')
      candidate['network'] = { 'dedicated' => true, 'bridge' => 'test-br' }
      candidate['services']['ip'] = '192.0.2.20'
      bridge = value.requested(candidate, 'single', 'bridge', identity, SecureRandom.uuid)
      assert_nil(bridge.fetch('multicast'))
      assert_equal([{ 'kind' => 'bridge-address', 'bridge' => 'test-br', 'address' => '192.0.2.20' }], bridge.fetch('resource_claims'))
    end
  end

  def engine(directory, claims)
    state = KbRuntime::State.new(directory, 'same-slug')
    LocalTransportEngine.new(state:, software: FakeSoftware.new, controller: [],
      resources: KbRuntime::Resources.new(state, root: claims))
  end

  def retained_files(value)
    [value.state.directory, value.resources.root].flat_map do |root|
      Dir.glob(File.join(root, '**', '*')).select { |path| File.file?(path) }
    end.to_h { |path| [path, [File.stat(path).ino, File.binread(path)]] }
  end

  %w[host port network].each do |change|
    define_method("test_update_rejects_changed_ssh_#{change}_before_any_retained_state_mutation") do
      Dir.mktmpdir do |directory|
        value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
        requested = config
        begin
          value.start(config: requested, network: 'local', timeout: 5)
          old = value.launch
          retained = retained_files(value)
          candidate = Marshal.load(Marshal.dump(requested))
          network = 'local'
          case change
          when 'host'
            candidate['local']['bindAddress'] = '127.0.0.2'
          when 'port'
            candidate['local']['ports']['services']['ssh'] = old['endpoints']['services']['port'] == 20_022 ? 20_023 : 20_022
          when 'network'
            network = 'bridge'
            candidate['services']['ip'] = '192.0.2.20'
            candidate['network'] = { 'dedicated' => true, 'bridge' => 'test-br' }
          end
          value.software.metadata['revision'] = 'b' * 40
          error = assert_raises(KbRuntime::Error) { value.update(config: candidate, topology: 'single', network:, timeout: 5) }
          assert_match(/unchanged SSH endpoints/, error.message)
          assert_equal(retained, retained_files(value), 'preflight must preserve files, credentials, journal and claims')
          assert_equal(old, value.launch)
          assert_equal('ready', value.phase['phase'])
          refute(File.exist?(value.state.path('update.json')))
          assert_equal(old['credential_identity'], KbRuntime::Software.credentials_identity(value.state.path('credentials')))
          assert_equal(1, value.software.builds)
          assert(value.live?(old))
        ensure
          value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
        end
      end
    end
  end

  def test_two_same_slug_runs_have_disjoint_resources_and_cleanup_only_their_own_instance
    Dir.mktmpdir do |directory|
      claims = File.join(directory, 'claims')
      first = engine(File.join(directory, 'first'), claims)
      second = engine(File.join(directory, 'second'), claims)
      begin
        first.start(config: config, network: 'local', timeout: 5)
        second.start(config: config, network: 'local', timeout: 5)
        refute_equal(first.launch['network_id'], second.launch['network_id'])
        refute_equal(first.launch['multicast']['port'], second.launch['multicast']['port'])
        refute_equal(first.launch['socket_dir'], second.launch['socket_dir'])
        refute_equal(first.launch['resource_claims'], second.launch['resource_claims'])
        first.stop(timeout: 5)
        first.reset
        assert(second.status['ready'])
        assert_equal(1, Dir.glob(File.join(claims, '*.json')).size)
        assert(File.directory?(second.state.directory))
      ensure
        [first, second].each do |value|
          value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
        end
      end
    end
  end

  def test_live_children_prevent_claim_release_and_eof_releases_capture_gate
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      begin
        value.start(config: config, network: 'local', timeout: 5)
        refute(value.gone?(value.launch))
        connection = value.state.file(value.state.path('connection.json'))
        input, writer = IO.pipe
        output_reader, output = IO.pipe
        lease = Thread.new do
          record = value.launch
          value.capture_lease(instance_id: record['instance_id'], run_id: record['run_id'],
            artifact_id: record['artifact_id'], artifact_sha256: record['artifact_sha256'],
            descriptor_sha256: Digest::SHA256.hexdigest(connection), input:, output:)
        end
        readiness = JSON.parse(Timeout.timeout(5) { output_reader.gets })
        assert_equal(value.launch['run_id'], readiness['run_id'])
        assert_raises(KbRuntime::Busy) { value.status }
        writer.close
        lease.value
        assert(value.status['ready'])
      ensure
        writer&.close unless writer&.closed?
        lease&.join
        [input, output, output_reader].each { |stream| stream&.close unless stream&.closed? }
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_failed_initial_build_has_no_runner_or_claim_and_can_only_be_reset_after_stop
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      value.software.define_singleton_method(:build) { |*_args| raise KbRuntime::Error, 'injected build failure' }
      assert_raises(KbRuntime::Error) { value.start(config: config, network: 'local') }
      assert_equal('building', value.phase['phase'])
      assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
      assert_empty(Dir.glob(File.join(value.state.directory, 'spawn-*.json')))
      assert_raises(KbRuntime::Error) { value.start(config: config, network: 'local') }
      value.stop
      assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
      value.reset
    end
  end

  def test_stop_resume_uses_the_same_artifact_and_retained_root_without_rebuilding
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      begin
        value.start(config: config, network: 'local', timeout: 5)
        old = value.launch
        root = File.join(old['state_dir'], 'services-root.img')
        File.write(root, 'root sentinel')
        old_stat = File.stat(root)
        value.stop(timeout: 5)
        assert_raises(KbRuntime::Error) { value.start(config: config, network: 'local', timeout: 5) }
        value.resume(timeout: 5)
        current = value.launch
        refute_equal(old['run_id'], current['run_id'])
        assert_equal(old['artifact_id'], current['artifact_id'])
        assert_equal(old['artifact_sha256'], current['artifact_sha256'])
        assert_equal(old['machine_toplevels'], current['machine_toplevels'])
        assert_equal(1, value.software.builds)
        assert_equal(old_stat.ino, File.stat(root).ino)
        assert_equal('root sentinel', File.read(root))
        assert_equal(old['credential_identity'], current['credential_identity'])
        refute(current['guest_identity'].key?('run_id'))
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_offline_source_mismatch_and_pending_update_cannot_resume
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      value.start(config: config, network: 'local', timeout: 5)
      value.stop(timeout: 5)
      value.software.metadata['revision'] = 'b' * 40
      assert_raises(KbRuntime::Error) { value.resume(timeout: 5) }
      assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
      value.software.metadata['revision'] = 'a' * 40
      value.state.write(value.state.path('update.json'), { 'stage' => 'building' })
      assert_raises(KbRuntime::Error) { value.resume(timeout: 5) }
      assert_equal(1, value.software.builds)
    end
  end

  def test_missing_root_or_preparation_receipt_refuses_cold_resume
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      value.start(config: config, network: 'local', timeout: 5)
      old = value.launch
      value.stop(timeout: 5)
      proof = value.state.path("prepared-#{old['artifact_id']}.json")
      bytes = File.binread(proof)
      File.unlink(proof)
      assert_raises(Errno::ENOENT) { value.resume(timeout: 5) }
      File.write(proof, bytes, mode: 'wb', perm: 0o600)
      File.unlink(File.join(old['state_dir'], 'services-root.img'))
      assert_raises(Errno::ENOENT) { value.resume(timeout: 5) }
      assert_equal(1, value.software.builds)
      assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
    end
  end

  def test_failed_candidate_build_preserves_the_live_predecessor_and_same_candidate_retry
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      requested = config
      begin
        value.start(config: requested, network: 'local', timeout: 5)
        old = value.launch
        root = File.join(old['state_dir'], 'services-root.img')
        old_root = File.stat(root).ino
        value.software.metadata['revision'] = 'b' * 40
        original_build = value.software.method(:build)
        value.software.define_singleton_method(:build) { |*_args| raise KbRuntime::Error, 'candidate build failed' }
        assert_raises(KbRuntime::Error) { value.update(config: requested, topology: 'single', network: 'local', timeout: 5) }
        assert(value.live?(old))
        assert_equal(old['run_id'], value.launch['run_id'])
        assert_equal('updating', value.phase['phase'])
        assert_equal('building', value.state.read(value.state.path('update.json'))['stage'])
        assert_equal(1, Dir.glob(File.join(value.resources.root, '*.json')).size)
        assert_raises(KbRuntime::Error) { value.resume(timeout: 5) }
        assert_raises(KbRuntime::Error) { value.update(config: config, topology: 'single', network: 'local', timeout: 5) }
        candidate = value.state.read(value.state.path('update.json'))['artifact_id']
        value.software.define_singleton_method(:build, original_build)
        value.update(config: requested, topology: 'single', network: 'local', timeout: 5)
        current = value.launch
        assert_equal(candidate, current['artifact_id'])
        refute_equal(old['artifact_id'], current['artifact_id'])
        refute_equal(old['run_id'], current['run_id'])
        assert_equal('b' * 40, current['guest_identity']['source']['revision'])
        assert(value.gone?(old))
        assert_equal(old_root, File.stat(root).ino)
        assert_equal('root sentinel', File.read(root))
        assert_equal(old['credential_identity'], current['credential_identity'])
        refute(File.exist?(value.state.path('update.json')))
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_import_failure_keeps_old_run_claims_and_resume_cannot_choose_an_old_artifact
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      requested = config
      begin
        value.start(config: requested, network: 'local', timeout: 5)
        old = value.launch
        value.software.metadata['revision'] = 'b' * 40
        value.preparation_failure = 'store import interrupted'
        assert_raises(KbRuntime::Error) { value.update(config: requested, topology: 'single', network: 'local', timeout: 5) }
        candidate = value.state.read(value.state.path('update.json'))
        assert_equal('preparing', candidate['stage'])
        assert(value.live?(old))
        assert_equal(old['artifact_id'], value.launch['artifact_id'])
        assert_equal(1, Dir.glob(File.join(value.resources.root, '*.json')).size)
        assert_raises(KbRuntime::Error) { value.resume(timeout: 5) }
        value.preparation_failure = nil
        value.update(config: requested, topology: 'single', network: 'local', timeout: 5)
        assert_equal(candidate['artifact_id'], value.launch['artifact_id'])
        assert_equal(2, value.software.builds)
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end
end
