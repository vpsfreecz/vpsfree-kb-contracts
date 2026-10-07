# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'stringio'
require_relative '../cluster/lib/kb_runtime'
require_relative '../cluster/launcher'

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

  def test_ip_inventory_is_available_on_single_without_enabling_storage_dependent_fixtures
    state = KbRuntime::State.new('/not-created', 'capabilities')
    engine = KbRuntime::Engine.new(state: state, software: nil, controller: [])
    single = engine.capabilities('endpoints' => { 'services' => {}, 'node1' => {} })
    assert_includes(single, 'ip-inventory')
    refute_includes(single, 'base-vps')
    refute_includes(single, 'snapshot')
    services_only = engine.capabilities('endpoints' => { 'services' => {} })
    refute_includes(services_only, 'ip-inventory')
    complete = engine.capabilities('endpoints' => { 'services' => {}, 'node1' => {}, 'node2' => {}, 'backuper1' => {} })
    assert_includes(complete, 'base-vps')
    assert_includes(complete, 'second-vps')
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
      identity = state.transaction(create: true) { state.initialize_identity }
      run_id = SecureRandom.uuid
      state.write(state.path('phase.json'), { 'phase' => 'verifying', 'run_id' => run_id })
      state.private_directory(state.path('credentials'), create: true)
      known = File.join(state.path('credentials'), 'known_hosts')
      File.write(known, '', mode: 'wb', perm: 0o600)
      engine = KbRuntime::Engine.new(state:, software: nil, controller: [])
      endpoint = { 'host' => '127.0.0.1', 'port' => 10_022 }
      key = Base64.strict_encode64([11].pack('N') + 'ssh-ed25519' + [32].pack('N') + "\x02" * 32)
      scan = lambda do |target, timeout:, deadline:|
        assert_equal(5, timeout)
        assert_operator(deadline, :>, Process.clock_gettime(Process::CLOCK_MONOTONIC))
        { stdout: "[#{target['host']}]:#{target['port']} ssh-ed25519 #{key}", stderr: '',
          exitstatus: 0, termsig: nil, deadline: false, truncated: false }
      end
      engine.stub(:live?, true) do
        engine.stub(:ssh_keyscan, scan) do
          record = identity.merge('run_id' => run_id, 'endpoints' => { 'services' => endpoint })
          engine.establish_ssh_trust(record, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10)
          retained = File.binread(known)
          engine.establish_ssh_trust(record, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10)
          assert_equal(retained, File.binread(known))
          [endpoint.merge('port' => 20_022), endpoint.merge('host' => '127.0.0.2')].each do |changed|
            assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record.merge('endpoints' => { 'services' => changed }), deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10) }
            assert_equal(retained, File.binread(known))
          end
          key = Base64.strict_encode64([11].pack('N') + 'ssh-ed25519' + [32].pack('N') + 'x' * 32)
          assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10) }
          assert_equal(retained, File.binread(known))
        end
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

class ProcessDiscoveryTest < Minitest::Test
  def test_workers_at_each_level_discover_exact_child_identities_without_threads_or_siblings
    child_program = <<~RUBY
      require 'json'
      require 'rbconfig'
      STDOUT.sync = true
      worker = Thread.new do
        reader, writer = IO.pipe
        pid = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: reader, out: File::NULL, err: File::NULL, close_others: true)
        reader.close
        puts JSON.generate('child' => Process.pid, 'child_task' => Thread.current.native_thread_id, 'grandchild' => pid)
        STDIN.read
      ensure
        writer&.close unless writer&.closed?
        Process.wait(pid) if pid
        reader&.close unless reader&.closed?
      end
      worker.value
    RUBY
    root_program = <<~RUBY
      require 'json'
      require 'rbconfig'
      STDOUT.sync = true
      worker = Thread.new do
        reader, writer = IO.pipe
        response, output = IO.pipe
        pid = Process.spawn(RbConfig.ruby, '-e', #{child_program.inspect}, in: reader, out: output, close_others: true)
        reader.close
        output.close
        value = JSON.parse(response.gets || raise('nested worker handshake failed'))
        puts JSON.generate(value.merge('root_task' => Thread.current.native_thread_id))
        STDIN.read
      ensure
        writer&.close unless writer&.closed?
        Process.wait(pid) if pid
        [reader, response, output].compact.each { |stream| stream.close unless stream.closed? }
      end
      worker.value
    RUBY
    sibling_reader, sibling_writer = IO.pipe
    sibling = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: sibling_reader, out: File::NULL, err: File::NULL, close_others: true)
    sibling_reader.close
    with_owned_root(root_program) do |pid, _command, response|
      info = JSON.parse(Timeout.timeout(5) { response.gets })
      refute_equal(pid, info['root_task'])
      refute_equal(info['child'], info['child_task'])
      expected = [info['child'], info['grandchild']].map { |child| KbRuntime::ProcessIdentity.read(child) }
      assert(expected.all?)
      observation = { incomplete: false }
      found = KbRuntime::ProcessIdentity.descendants(pid, observation:)
      assert_equal(expected.sort_by { |record| record['pid'] }, found.sort_by { |record| record['pid'] })
      assert_equal(found, observation[:records])
      refute(observation[:incomplete])
      assert_equal(found.size, found.map { |record| [record['pid'], record['start_ticks']] }.uniq.size)
      [pid, sibling, info['root_task'], info['child_task']].each { |excluded| refute_includes(found.map { |record| record['pid'] }, excluded) }
      assert(KbRuntime::ProcessIdentity.matches?(KbRuntime::ProcessIdentity.read(sibling)))
    end
  ensure
    sibling_writer&.close unless sibling_writer&.closed?
    Process.wait(sibling) if sibling
    sibling_reader&.close unless sibling_reader&.closed?
  end

  def test_worker_exit_after_the_parent_list_marks_the_pass_incomplete_and_preserves_reparented_children
    program = <<~'RUBY'
      require 'json'
      require 'rbconfig'
      require 'timeout'
      STDOUT.sync = true
      begin
        first_reader, first_writer = IO.pipe
        first = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: first_reader, out: File::NULL, err: File::NULL, close_others: true)
        first_reader.close
        exit_worker = Queue.new
        started = Queue.new
        held = {}
        worker = Thread.new do
          reader, writer = IO.pipe
          held[:writer] = writer
          held[:pid] = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: reader, out: File::NULL, err: File::NULL, close_others: true)
          reader.close
          held[:task] = Thread.current.native_thread_id
          started << { 'first' => first, 'late' => held[:pid], 'task' => held[:task] }
          exit_worker.pop
        end
        puts JSON.generate(started.pop)
        while (command = STDIN.gets)
          case command.strip
          when 'worker-exit'
            exit_worker << true
            worker.value
            Timeout.timeout(5) { Thread.pass while File.directory?("/proc/#{Process.pid}/task/#{held[:task]}") }
            puts JSON.generate('worker_gone' => true)
          when 'exit-first'
            first_writer.close
            Process.wait(first)
            first = nil
            puts JSON.generate('first_gone' => true)
          else
            raise 'unexpected fixture command'
          end
        end
      ensure
        exit_worker << true if worker&.alive?
        worker&.join
        first_writer&.close unless first_writer&.closed?
        held&.fetch(:writer, nil)&.close unless held&.fetch(:writer, nil)&.closed?
        Process.wait(first) if first
        Process.wait(held[:pid]) if held && held[:pid]
        first_reader&.close unless first_reader&.closed?
      end
    RUBY
    with_owned_root(program) do |pid, command, response|
      info = JSON.parse(Timeout.timeout(5) { response.gets })
      first, late = [info['first'], info['late']].map { |child| KbRuntime::ProcessIdentity.read(child) }
      assert(first && late)
      read = File.method(:read)
      list = Dir.method(:children)
      crossed = false
      task_directory = "/proc/#{pid}/task"
      parent_children = "#{task_directory}/#{pid}/children"
      ordered = lambda do |path|
        values = list.call(path)
        path == task_directory ? [pid.to_s, *(values - [pid.to_s])] : values
      end
      interleaved = lambda do |path, *args, **options|
        bytes = read.call(path, *args, **options)
        if path == parent_children && !crossed
          crossed = true
          refute_includes(bytes.split, info['late'].to_s)
          command.puts('worker-exit')
          assert_equal({ 'worker_gone' => true }, JSON.parse(Timeout.timeout(5) { response.gets }))
          assert_includes(read.call(parent_children).split, info['late'].to_s, 'the child was reparented to the already-read task')
        end
        bytes
      end
      observation = { incomplete: false }
      found = nil
      Dir.stub(:children, ordered) do
        File.stub(:read, interleaved) { found = KbRuntime::ProcessIdentity.descendants(pid, observation:) }
      end
      assert(crossed)
      assert(observation[:incomplete], 'a vanished listed worker cannot authorize terminal proof')
      assert_equal([first], found)
      assert_equal(found, observation[:records])
      next_pass = { incomplete: false }
      discovered = KbRuntime::ProcessIdentity.descendants(pid, observation: next_pass)
      assert_equal([first, late].sort_by { |record| record['pid'] }, discovered.sort_by { |record| record['pid'] })
      refute(next_pass[:incomplete])
      retained = (found + discovered).to_h { |record| [[record['pid'], record['start_ticks']], record] }
      command.puts('exit-first')
      assert_equal({ 'first_gone' => true }, JSON.parse(Timeout.timeout(5) { response.gets }))
      assert(KbRuntime::ProcessIdentity.gone?(first))
      assert(KbRuntime::ProcessIdentity.matches?(late))
      assert_equal([late], KbRuntime::ProcessIdentity.descendants(pid))
      assert_equal(2, retained.size, 'an exited or reparented identity is retained until its own exit proof')
    end
  end

  def test_a_vanished_task_keeps_other_collected_children_and_marks_the_pass_incomplete
    [Errno::ENOENT, Errno::ESRCH].each do |missing|
      observation = { incomplete: false }
      read = lambda do |path|
        next '51 51' if path == '/proc/42/task/42/children'
        raise missing, path if path == '/proc/42/task/43/children'
        flunk("unexpected child path: #{path}")
      end
      disappeared = ->(path) { assert_equal('/proc/42/task/43', path); raise missing, path }
      Dir.stub(:children, %w[42 43]) do
        File.stub(:read, read) do
          File.stub(:stat, disappeared) { assert_equal([51], KbRuntime::ProcessIdentity.children(42, observation:)) }
        end
      end
      assert(observation[:incomplete])
    end
  end

  def test_missing_child_data_for_a_live_task_is_a_refusal_not_disappearance
    [Errno::ENOENT, Errno::ESRCH].each do |missing|
      observation = { incomplete: false }
      File.stub(:stat, ->(path) { assert_equal('/proc/42/task/42', path); Object.new }) do
        Dir.stub(:children, ['42']) do
          File.stub(:read, ->(path) { raise missing, path }) do
            assert_raises(missing) { KbRuntime::ProcessIdentity.children(42, observation:) }
          end
        end
      end
      refute(observation[:incomplete])
    end
  end

  def test_a_changed_task_set_marks_the_collected_result_incomplete_without_retrying
    enumerations = 0
    tasks = lambda do |path|
      assert_equal('/proc/42/task', path)
      enumerations += 1
      enumerations == 1 ? %w[42 43] : ['42']
    end
    observation = { incomplete: false }
    Dir.stub(:children, tasks) do
      File.stub(:read, ->(path) { path == '/proc/42/task/42/children' ? '51' : '52' }) do
        assert_equal([51, 52], KbRuntime::ProcessIdentity.children(42, observation:))
      end
    end
    assert_equal(2, enumerations)
    assert(observation[:incomplete])
  end

  def test_permission_malformed_task_and_malformed_child_data_refuse
    Dir.stub(:children, ->(_path) { raise Errno::EACCES }) { assert_raises(Errno::EACCES) { KbRuntime::ProcessIdentity.children(42) } }
    Dir.stub(:children, ['42']) do
      File.stub(:read, ->(_path) { raise Errno::EACCES }) { assert_raises(Errno::EACCES) { KbRuntime::ProcessIdentity.children(42) } }
    end
    %w[../43 task -43 0 043].each do |invalid|
      Dir.stub(:children, ['42', invalid]) do
        File.stub(:read, ->(_path) { flunk('malformed task paths must never be opened') }) do
          assert_raises(KbRuntime::Error) { KbRuntime::ProcessIdentity.children(42) }
        end
      end
    end
    %w[-51 +51 child 0 1 051].each do |invalid|
      Dir.stub(:children, ['42']) do
        File.stub(:read, "51 #{invalid}") { assert_raises(KbRuntime::Error) { KbRuntime::ProcessIdentity.children(42) } }
      end
    end
  end

  def test_identity_visited_set_deduplicates_cycles_and_reparenting_observations
    records = [42, 51, 52].to_h { |pid| [pid, identity(pid)] }
    graph = { 42 => [51, 51], 51 => [52], 52 => [51, 42] }
    visits = []
    children = ->(pid, **_options) { visits << pid; graph.fetch(pid) }
    KbRuntime::ProcessIdentity.stub(:read, ->(pid) { records.fetch(pid) }) do
      KbRuntime::ProcessIdentity.stub(:children, children) do
        assert_equal([records[51], records[52]], KbRuntime::ProcessIdentity.descendants(42))
      end
    end
    assert_equal([42, 51, 52], visits)
  end

  def test_recursive_exit_or_reused_pid_keeps_the_captured_identity_without_following_the_replacement
    [nil, identity(51).merge('start_ticks' => 999)].each do |replacement|
      records = { 42 => identity(42), 51 => identity(51) }
      child_reads = 0
      visits = []
      read = lambda do |pid|
        next records.fetch(42) if pid == 42
        child_reads += 1
        child_reads == 1 ? records.fetch(51) : replacement
      end
      children = ->(pid, **_options) { visits << pid; assert_equal(42, pid); [51] }
      observation = { incomplete: false }
      KbRuntime::ProcessIdentity.stub(:boot_id, 'synthetic-boot') do
        KbRuntime::ProcessIdentity.stub(:read, read) do
          KbRuntime::ProcessIdentity.stub(:children, children) do
            assert_equal([records[51]], KbRuntime::ProcessIdentity.descendants(42, observation:))
          end
        end
      end
      assert_equal([42], visits)
      assert(observation[:incomplete])
    end
  end

  def test_changed_live_identity_and_live_missing_task_directory_refuse_without_losing_captured_records
    [{'owner_uid' => Process.uid + 1}, { 'boot_id' => 'different-boot' }, { 'executable' => '/different' }, { 'argv' => ['different'] }].each do |change|
      root, child = identity(42), identity(51)
      calls = 0
      read = lambda do |pid|
        next root if pid == 42
        calls += 1
        calls == 1 ? child : child.merge(change)
      end
      observation = { incomplete: false }
      KbRuntime::ProcessIdentity.stub(:boot_id, 'synthetic-boot') do
        KbRuntime::ProcessIdentity.stub(:read, read) do
          KbRuntime::ProcessIdentity.stub(:children, ->(pid, **_options) { assert_equal(42, pid); [51] }) do
            assert_raises(KbRuntime::Error) { KbRuntime::ProcessIdentity.descendants(42, observation:) }
          end
        end
      end
      assert_equal([child], observation[:records])
    end
    root = identity(42)
    observation = { incomplete: false }
    KbRuntime::ProcessIdentity.stub(:read, root) do
      Dir.stub(:children, ->(_path) { raise Errno::ENOENT }) do
        assert_raises(Errno::ENOENT) { KbRuntime::ProcessIdentity.descendants(42, observation:) }
      end
    end
    refute(observation[:incomplete])
  end

  def test_a_recursive_live_missing_child_file_refuses_but_keeps_other_observed_identities
    records = [42, 51, 52].to_h { |pid| [pid, identity(pid)] }
    lists = { '/proc/42/task' => ['42'], '/proc/51/task' => ['51'], '/proc/52/task' => ['52'] }
    read = lambda do |path|
      case path
      when '/proc/42/task/42/children' then '51 52'
      when '/proc/51/task/51/children' then ''
      when '/proc/52/task/52/children' then raise Errno::ENOENT, path
      else flunk("unexpected child path: #{path}")
      end
    end
    observation = { incomplete: false }
    KbRuntime::ProcessIdentity.stub(:read, ->(pid) { records.fetch(pid) }) do
      Dir.stub(:children, ->(path) { lists.fetch(path) }) do
        File.stub(:read, read) do
          File.stub(:stat, ->(path) { assert_equal('/proc/52/task/52', path); Object.new }) do
            assert_raises(Errno::ENOENT) { KbRuntime::ProcessIdentity.descendants(42, observation:) }
          end
        end
      end
    end
    assert_equal([records[51], records[52]], observation[:records])
    refute(observation[:incomplete], 'unsupported live data remains an error, not an ordinary exit')
  end

  def identity(pid)
    { 'pid' => pid, 'start_ticks' => pid * 10, 'boot_id' => 'synthetic-boot', 'owner_uid' => Process.uid,
      'executable' => RbConfig.ruby, 'argv' => ['synthetic', pid.to_s] }
  end

  def with_owned_root(program)
    Dir.mktmpdir('kb-task-fixture-', '/tmp') do |directory|
      input, command = IO.pipe
      response, output = IO.pipe
      diagnostic = File.open(File.join(directory, 'stderr'), File::WRONLY | File::CREAT | File::EXCL, 0o600)
      pid = Process.spawn(RbConfig.ruby, '-e', program, in: input, out: output, err: diagnostic, close_others: true)
      input.close
      output.close
      yield pid, command, response
    ensure
      primary = $!
      command&.close unless command&.closed?
      begin
        status = Timeout.timeout(5) { Process.waitpid2(pid).last } if pid
        assert(status.success?, File.read(File.join(directory, 'stderr')).byteslice(0, 2048)) if status && !primary
      rescue StandardError, Minitest::Assertion => cleanup_error
        raise unless primary
        warn "Owned discovery fixture cleanup failed: #{cleanup_error.class}: #{cleanup_error.message.to_s.lines.first.to_s.strip}"
      ensure
        [input, command, response, output, diagnostic].compact.each { |stream| stream.close unless stream.closed? }
      end
    end
  end
end

class SshDiscoveryTest < Minitest::Test
  def test_delayed_keys_succeed_within_the_original_deadline
    with_discovery do |engine, record, known, clock|
      results = [{ stdout: '', exitstatus: 1, stderr: 'not listening', elapsed: 0.2 },
        { stdout: key(record['endpoints']['services']), elapsed: 0.2 }]
      with_scans(engine, clock, results) do |calls|
        engine.establish_ssh_trust(record, deadline: 105.0)
        assert_equal(2, calls.length)
        assert_equal([105.0, 105.0], calls.map { |call| call[:deadline] })
        assert_equal([5, 4], calls.map { |call| call[:timeout] })
        assert_equal("#{key(record['endpoints']['services'])}\n", File.binread(known))
      end
    end
  end

  def test_permanent_transport_failure_retains_native_private_diagnostics
    with_discovery do |engine, record, known, clock|
      native = { stdout: '', stderr: "native private banner\n", exitstatus: 23, elapsed: 1.0 }
      with_scans(engine, clock, [native, native]) do |calls|
        error = assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 103.0) }
        assert_equal(2, calls.length)
        assert_match(/services 127\.0\.0\.1:10022/, error.message)
        assert_match(/attempts=2 .*status=exit-23 diagnostics=/, error.message)
        refute_includes(error.message, 'native private banner')
        assert_equal('', File.binread(known))
        diagnostics(engine).each do |path, value|
          assert_equal(0o600, File.stat(path).mode & 0o777)
          assert_equal(record['run_id'], value['run_id'])
          assert_equal('services', value['machine'])
          assert_equal(record['endpoints']['services'], value['endpoint'])
          assert_equal(23, value['exitstatus'])
          assert_nil(value['termsig'])
          assert_equal('', Base64.strict_decode64(value['stdout_base64']))
          assert_equal(native[:stderr], Base64.strict_decode64(value['stderr_base64']))
          assert_includes(error.message, path) if value['attempt'] == 2
        end
        assert_equal(2, diagnostics(engine).length)
      end
    end
  end

  def test_all_endpoints_share_one_deadline_and_integer_scan_allowance
    with_discovery(endpoints: two_endpoints) do |engine, record, known, clock|
      results = [{ stdout: key(two_endpoints['services']), elapsed: 3.2 },
        { stdout: key(two_endpoints['node1']), elapsed: 0.2 }]
      with_scans(engine, clock, results) do |calls|
        engine.establish_ssh_trust(record, deadline: 105.0)
        assert_equal([5, 1], calls.map { |call| call[:timeout] })
        assert_equal([105.0, 105.0], calls.map { |call| call[:deadline] })
        assert_equal(two_endpoints.values, calls.map { |call| call[:endpoint] })
        assert_equal(two_endpoints.values.map { |endpoint| "#{key(endpoint)}\n" }.join, File.binread(known))
      end
    end
  end

  def test_subsecond_remaining_allowance_refuses_before_scanning_next_endpoint
    with_discovery(endpoints: two_endpoints) do |engine, record, known, clock|
      with_scans(engine, clock, [{ stdout: key(two_endpoints['services']), elapsed: 4.5 }]) do |calls|
        error = assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
        assert_equal(1, calls.length)
        assert_match(/node1 .*attempts=0 .*status=not-run/, error.message)
        assert_equal('', File.binread(known), 'one successful endpoint must not publish partial trust')
        assert_equal(1, diagnostics(engine).length)
      end
    end
  end

  def test_expired_deadline_has_no_scan_or_trust_write
    with_discovery do |engine, record, known, clock|
      before = [File.stat(known).ino, File.binread(known)]
      with_scans(engine, clock, []) do |calls|
        assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: clock.now) }
        assert_empty(calls)
        assert_empty(diagnostics(engine))
        assert_equal(before, [File.stat(known).ino, File.binread(known)])
      end
    end
  end

  def test_late_success_is_not_accepted
    with_discovery do |engine, record, known, clock|
      with_scans(engine, clock, [{ stdout: key(record['endpoints']['services']), elapsed: 5.0 }]) do |calls|
        assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
        assert_equal(1, calls.length)
        assert_equal('', File.binread(known))
        assert_equal(1, diagnostics(engine).length)
      end
    end
  end

  def test_runner_loss_after_scan_refuses_acceptance_without_retry
    with_discovery do |engine, record, known, _clock|
      live = true
      calls = 0
      engine.define_singleton_method(:live?) { |_record| live }
      scan = lambda do |_endpoint, **_options|
        calls += 1
        live = false
        native(stdout: key(record['endpoints']['services']))
      end
      engine.stub(:ssh_keyscan, scan) do
        error = assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
        assert_match(/recorded live run/, error.message)
      end
      assert_equal(1, calls)
      assert_equal('', File.binread(known))
    end
  end

  def test_foreign_launch_identity_refuses_before_scan
    with_discovery do |engine, record, known, clock|
      with_scans(engine, clock, []) do |calls|
        assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record.merge('instance_id' => SecureRandom.uuid), deadline: 105.0) }
        assert_empty(calls)
        assert_equal('', File.binread(known))
      end
    end
  end

  def test_malformed_wrong_endpoint_and_invalid_wire_keys_refuse_immediately
    endpoint = two_endpoints['services']
    malformed = ['not key data', key(endpoint.merge('port' => 10023)),
      "[127.0.0.1]:10022 ssh-ed25519 invalid-base64", "#{key(endpoint)} extra",
      "#{key(endpoint)}\nwrong endpoint", key(endpoint).sub('ssh-ed25519', 'ssh-rsa')]
    malformed.each do |output|
      with_discovery do |engine, record, known, clock|
        with_scans(engine, clock, [{ stdout: output }]) do |calls|
          error = assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
          assert_match(/invalid SSH host key data/, error.message)
          refute_includes(error.message, output)
          assert_equal(1, calls.length)
          assert_equal('', File.binread(known))
          assert_equal(output, Base64.strict_decode64(diagnostics(engine).values.first['stdout_base64']))
        end
      end
    end
  end

  def test_retained_valid_key_mismatch_neither_retries_nor_rewrites
    retained = "#{key(two_endpoints['services'], 'a')}\n"
    with_discovery(retained:) do |engine, record, known, clock|
      before = [File.stat(known).ino, File.binread(known)]
      with_scans(engine, clock, [{ stdout: key(record['endpoints']['services'], 'b') }]) do |calls|
        error = assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
        assert_match(/retained trust is not replaced/, error.message)
        assert_equal(1, calls.length)
        assert_equal(before, [File.stat(known).ino, File.binread(known)])
      end
    end
  end

  def test_second_endpoint_failure_does_not_publish_first_endpoint_trust
    with_discovery(endpoints: two_endpoints) do |engine, record, known, clock|
      results = [{ stdout: key(two_endpoints['services']) },
        { stdout: '', exitstatus: 1, elapsed: 1.0 }, { stdout: '', exitstatus: 1, elapsed: 1.0 }]
      with_scans(engine, clock, results) do |calls|
        assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 103.0) }
        assert_equal([two_endpoints['services'], two_endpoints['node1'], two_endpoints['node1']], calls.map { |call| call[:endpoint] })
        assert_equal('', File.binread(known))
        assert_equal(%w[services node1 node1].sort, diagnostics(engine).values.map { |value| value['machine'] }.sort)
      end
    end
  end

  def test_tool_invocation_failure_is_immediate_and_private
    with_discovery do |engine, record, known, clock|
      with_scans(engine, clock, [Errno::ENOENT.new('private executable detail')]) do |calls|
        error = assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
        assert_match(/invocation failed.*status=Errno::ENOENT diagnostics=/, error.message)
        refute_includes(error.message, 'private executable detail')
        assert_equal(1, calls.length)
        assert_equal('', File.binread(known))
        value = diagnostics(engine).values.first
        assert_equal('Errno::ENOENT', value['invocation_error'])
        assert_includes(Base64.strict_decode64(value['stderr_base64']), 'private executable detail')
      end
    end
  end

  def test_signalled_keyscan_refuses_immediately_without_retry
    with_discovery do |engine, record, known, clock|
      with_scans(engine, clock, [{ exitstatus: nil, termsig: Signal.list.fetch('TERM') }]) do |calls|
        error = assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
        assert_match(/terminated.*status=signal-15 diagnostics=/, error.message)
        assert_equal(1, calls.length)
        assert_equal('', File.binread(known))
      end
    end
  end

  def test_stderr_banner_does_not_replace_or_enter_known_hosts
    with_discovery do |engine, record, known, clock|
      stdout = "# keyscan comment\n#{key(record['endpoints']['services'])}\n"
      with_scans(engine, clock, [{ stdout:, stderr: 'private diagnostic banner' }]) do |calls|
        engine.establish_ssh_trust(record, deadline: 105.0)
        assert_equal(1, calls.length)
        assert_equal("#{key(record['endpoints']['services'])}\n", File.binread(known))
        assert_equal('private diagnostic banner', Base64.strict_decode64(diagnostics(engine).values.first['stderr_base64']))
      end
    end
  end

  def test_bridge_endpoint_accepts_complete_keyscan_key_types_without_forwarding_prefix
    endpoint = { 'host' => '192.0.2.20', 'port' => 22, 'user' => 'root' }
    fields = lambda do |parts|
      Base64.strict_encode64(parts.map { |part| [part.bytesize].pack('N') + part }.join)
    end
    keys = [
      "#{endpoint['host']} ssh-ed25519 #{fields.call(['ssh-ed25519', 'k' * 32])}",
      "#{endpoint['host']} ssh-rsa #{fields.call(['ssh-rsa', "\x01\x00\x01", "\x00\x80" + 'n' * 255])}",
      "#{endpoint['host']} ecdsa-sha2-nistp256 #{fields.call(['ecdsa-sha2-nistp256', 'nistp256', "\x04" + 'p' * 64])}"
    ]
    with_discovery(endpoints: { 'services' => endpoint }) do |engine, record, known, clock|
      with_scans(engine, clock, [{ stdout: keys.join("\n") }]) do |calls|
        engine.establish_ssh_trust(record, deadline: 105.0)
        assert_equal(1, calls.length)
        assert_equal(endpoint, calls.first[:endpoint])
        assert_equal("#{keys.join("\n")}\n", File.binread(known))
      end
    end
  end

  def test_truncated_native_capture_refuses_instead_of_accepting_partial_keys
    with_discovery do |engine, record, known, clock|
      with_scans(engine, clock, [{ stdout: key(record['endpoints']['services']), truncated: true }]) do |calls|
        assert_raises(KbRuntime::Error) { engine.establish_ssh_trust(record, deadline: 105.0) }
        assert_equal(1, calls.length)
        assert_equal('', File.binread(known))
      end
    end
  end

  def test_ssh_specific_capture_preserves_native_streams_status_argv_and_clears_overrides
    state = KbRuntime::State.new('/not-created', 'ssh-capture')
    engine = KbRuntime::Engine.new(state:, software: nil, controller: [])
    saved = ENV['SSH_AUTH_SOCK']
    ENV['SSH_AUTH_SOCK'] = '/not-used/agent'
    original = Process.method(:spawn)
    child = nil
    spawn = lambda do |environment, command, *args, **options|
      assert_equal('ssh-keyscan', command)
      assert_equal(['-T', '1', '-p', '10022', '127.0.0.1'], args)
      assert_nil(environment['SSH_AUTH_SOCK'])
      assert_equal(File::NULL, options[:in])
      assert_equal(true, options[:close_others])
      child = original.call(environment, RbConfig.ruby, '-e', 'STDOUT.write("native keys"); STDERR.write("native error"); exit 7', **options)
    end
    result = Process.stub(:spawn, spawn) do
      engine.ssh_keyscan(two_endpoints['services'], timeout: 1, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5)
    end
    assert_equal('native keys', result[:stdout])
    assert_equal('native error', result[:stderr])
    assert_equal(7, result[:exitstatus])
    assert_nil(result[:termsig])
    refute(result[:deadline])
    refute(result[:truncated])
    assert_raises(Errno::ECHILD) { Process.waitpid(child, Process::WNOHANG) }
  ensure
    ENV['SSH_AUTH_SOCK'] = saved
  end

  def test_scan_deadline_and_output_bound_reap_only_the_owned_child
    [:deadline, :output].each do |kind|
      engine = KbRuntime::Engine.new(state: KbRuntime::State.new('/not-created', 'ssh-capture'), software: nil, controller: [])
      original = Process.method(:spawn)
      child = nil
      program = kind == :output ? 'STDOUT.sync=true; STDOUT.write("x" * 30_000); sleep 30' : 'STDERR.sync=true; STDERR.write("waiting"); sleep 30'
      spawn = lambda do |environment, _command, *_args, **options|
        child = original.call(environment, RbConfig.ruby, '-e', program, **options)
      end
      remaining = kind == :deadline ? 0.2 : 5
      result = Timeout.timeout(10) do
        Process.stub(:spawn, spawn) do
          engine.ssh_keyscan(two_endpoints['services'], timeout: 1, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + remaining)
        end
      end
      assert_equal(kind == :deadline, result[:deadline])
      assert_equal(kind == :output, result[:truncated])
      assert_equal(Signal.list.fetch('KILL'), result[:termsig])
      assert_operator(result[:stdout].bytesize, :<=, 16 * 1024)
      assert_operator(result[:stderr].bytesize, :<=, 16 * 1024)
      assert_raises(Errno::ECHILD) { Process.waitpid(child, Process::WNOHANG) }
    end
  end

  def test_interrupt_after_real_polling_reap_cannot_signal_the_reaped_pid
    with_interrupted_scan(interrupt_at: :poll) do |engine, observed|
      assert_raises(Interrupt) { run_interrupted_scan(engine) }
      assert_equal([:poll], observed[:queued])
      assert_equal([observed[:child]], observed[:reaped])
      assert_empty(observed[:signals])
      assert_scan_child_released(observed)
    end
  end

  def test_interrupt_after_real_spawn_retains_pid_until_exact_child_cleanup
    with_interrupted_scan(interrupt_at: :spawn) do |engine, observed|
      assert_raises(Interrupt) { run_interrupted_scan(engine) }
      assert_equal([:spawn], observed[:queued])
      assert_equal([['KILL', observed[:child]]], observed[:signals])
      assert_scan_child_released(observed)
    end
  end

  def test_interrupt_after_either_real_pipe_acquisition_closes_every_returned_endpoint
    [1, 2].each do |pipe_index|
      with_interrupted_scan(interrupt_at: :pipe, pipe_index:) do |engine, observed|
        assert_raises(Interrupt) { run_interrupted_scan(engine) }
        assert_equal([:pipe], observed[:queued])
        assert_equal([['KILL', observed[:child]]], observed[:signals])
        assert_scan_child_released(observed)
      end
    end
  end

  def test_interrupt_after_deadline_terminal_reap_has_no_second_signal
    with_interrupted_scan(interrupt_at: :terminal) do |engine, observed|
      assert_raises(Interrupt) { run_interrupted_scan(engine, remaining: 0.2) }
      assert_equal([:terminal], observed[:queued])
      assert_equal([['KILL', observed[:child]]], observed[:signals])
      assert_equal(Signal.list.fetch('KILL'), observed[:statuses].last.termsig)
      assert_scan_child_released(observed)
    end
  end

  def test_second_interrupt_during_ensure_terminal_reap_cannot_skip_endpoint_closure
    with_interrupted_scan(interrupt_at: :spawn, second_interrupt: true) do |engine, observed|
      assert_raises(Interrupt) { run_interrupted_scan(engine) }
      assert_equal([:spawn, :terminal], observed[:queued])
      assert_equal([['KILL', observed[:child]]], observed[:signals])
      assert_scan_child_released(observed)
    end
  end

  def test_echild_invalidates_signal_authority_with_and_without_pending_interrupt
    [false, true].each do |interrupt|
      with_interrupted_scan(interrupt_at: interrupt ? :echild : nil, echild: true) do |engine, observed|
        assert_raises(interrupt ? Interrupt : Errno::ECHILD) { run_interrupted_scan(engine) }
        assert_equal(interrupt ? [:echild] : [], observed[:queued])
        assert_empty(observed[:signals])
        assert_scan_child_released(observed)
      end
    end
  end

  private

  def run_interrupted_scan(engine, remaining: 5)
    Timeout.timeout(10) do
      engine.ssh_keyscan(two_endpoints['services'], timeout: 1,
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + remaining)
    end
  end

  def assert_scan_child_released(observed)
    assert_equal([observed[:child]], observed[:reaped], 'the real child must be reaped exactly once')
    assert_equal(4, observed[:pipes].length)
    observed[:pipes].each { |stream| assert(stream.closed?, 'every acquired pipe endpoint must close') }
    assert_empty(observed[:post_reap_signals], 'never signal a reaped PID, even in a failing regression')
    assert_raises(Errno::ECHILD) { Process.waitpid(observed[:child], Process::WNOHANG) }
  end

  def with_interrupted_scan(interrupt_at:, pipe_index: 1, echild: false, second_interrupt: false)
    engine = KbRuntime::Engine.new(state: KbRuntime::State.new('/not-created', 'ssh-capture'), software: nil, controller: [])
    spawn_child = Process.method(:spawn)
    wait_child = Process.method(:waitpid2)
    signal_child = Process.method(:kill)
    acquire_pipe = IO.method(:pipe)
    target = Thread.current
    observed = { child: nil, pipes: [], reaped: [], statuses: [], signals: [], post_reap_signals: [], queued: [] }
    enqueue = lambda do |boundary|
      observed[:queued] << boundary
      # Queue supported asynchronous delivery from another thread after the
      # real acquisition/reap but before the wrapper returns to its caller.
      Thread.new { target.raise(Interrupt, "queued at #{boundary}") }.join
    end
    pipe_count = 0
    pipe = lambda do |*args|
      endpoints = acquire_pipe.call(*args)
      observed[:pipes].concat(endpoints)
      pipe_count += 1
      enqueue.call(:pipe) if interrupt_at == :pipe && pipe_count == pipe_index
      endpoints
    end
    program = interrupt_at == :poll || echild ? 'exit 0' : 'sleep 30'
    spawn = lambda do |environment, _command, *_args, **options|
      observed[:child] = spawn_child.call(environment, RbConfig.ruby, '-e', program, **options)
      enqueue.call(:spawn) if interrupt_at == :spawn
      observed[:child]
    end
    wait = lambda do |pid, *flags|
      result = wait_child.call(pid, *flags)
      if result
        observed[:reaped] << pid
        observed[:statuses] << result.last
        if echild
          # Produce native ECHILD from this same already-reaped test child;
          # no competing reaper or unrelated PID is involved.
          begin
            wait_child.call(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            enqueue.call(:echild) if interrupt_at == :echild
            raise
          end
          flunk('a second native wait unexpectedly succeeded')
        elsif flags == [Process::WNOHANG] && interrupt_at == :poll
          enqueue.call(:poll)
        elsif flags.empty? && (interrupt_at == :terminal || second_interrupt)
          enqueue.call(:terminal)
        end
      end
      result
    end
    kill = lambda do |signal, pid|
      if observed[:reaped].include?(pid)
        observed[:post_reap_signals] << [signal, pid]
        raise 'refused post-reap signal in test fixture'
      end
      assert_equal(observed[:child], pid, 'only the retained owned child can be signalled')
      observed[:signals] << [signal, pid]
      signal_child.call(signal, pid)
    end
    IO.stub(:pipe, pipe) do
      Process.stub(:spawn, spawn) do
        Process.stub(:waitpid2, wait) do
          Process.stub(:kill, kill) { yield engine, observed }
        end
      end
    end
  ensure
    # Saved native methods provide bounded fixture cleanup on assertion failure.
    # This sole parent never sends a signal after one of its successful waits.
    begin
      if observed && observed[:child] && !observed[:reaped].include?(observed[:child])
        result = wait_child.call(observed[:child], Process::WNOHANG)
        unless result
          signal_child.call('KILL', observed[:child])
          wait_child.call(observed[:child])
        end
      end
    ensure
      observed&.fetch(:pipes)&.each { |stream| stream.close unless stream.closed? }
    end
  end

  def two_endpoints
    { 'services' => { 'host' => '127.0.0.1', 'port' => 10022, 'user' => 'root' },
      'node1' => { 'host' => '127.0.0.1', 'port' => 10023, 'user' => 'root' } }
  end

  def key(endpoint, fill = 'k')
    wire = [11].pack('N') + 'ssh-ed25519' + [32].pack('N') + fill * 32
    "[#{endpoint['host']}]:#{endpoint['port']} ssh-ed25519 #{Base64.strict_encode64(wire)}"
  end

  def native(**values)
    { stdout: '', stderr: '', exitstatus: 0, termsig: nil, deadline: false, truncated: false }.merge(values)
  end

  def with_discovery(endpoints: { 'services' => { 'host' => '127.0.0.1', 'port' => 10022, 'user' => 'root' } }, retained: '')
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'ssh-discovery')
      identity = state.transaction(create: true) { state.initialize_identity }
      record = identity.merge('run_id' => SecureRandom.uuid, 'endpoints' => endpoints)
      state.write(state.path('phase.json'), { 'phase' => 'verifying', 'run_id' => record['run_id'] })
      state.private_directory(state.path('credentials'), create: true)
      known = File.join(state.path('credentials'), 'known_hosts')
      File.write(known, retained, mode: 'wb', perm: 0o600)
      engine = KbRuntime::Engine.new(state:, software: nil, controller: [])
      engine.define_singleton_method(:live?) { |seen| seen == record }
      clock = Struct.new(:now).new(100.0)
      engine.define_singleton_method(:sleep) { |seconds| clock.now += seconds }
      Process.stub(:clock_gettime, ->(_kind) { clock.now }) { yield engine, record, known, clock }
    end
  end

  def with_scans(engine, clock, results)
    calls = []
    scan = lambda do |endpoint, timeout:, deadline:|
      calls << { endpoint:, timeout:, deadline: }
      assert_operator(timeout, :>=, 1)
      assert_operator(timeout, :<=, 5)
      assert_operator(timeout, :<=, (deadline - clock.now).floor)
      item = results.shift
      refute_nil(item, 'unexpected extra keyscan')
      raise item if item.is_a?(Exception)
      clock.now += item.fetch(:elapsed, 0)
      native(**item.reject { |name, _value| name == :elapsed })
    end
    engine.stub(:ssh_keyscan, scan) { yield calls }
  end

  def diagnostics(engine)
    Dir.glob(File.join(engine.state.directory, 'ssh-*.json')).sort.to_h { |path| [path, engine.state.read(path)] }
  end
end

class AtomicRecordReadTest < Minitest::Test
  def test_atomic_rename_returns_complete_replacement_bytes_and_json
    %i[file read].each do |method|
      with_record do |state, path|
        bytes = "#{JSON.generate('value' => 'replacement', 'items' => [1, 2, 3])}\n"
        replace = lambda do |events|
          replace_record(path, bytes) if events[:opens] == 1
        end
        with_record_opens(path, before_open: replace) do |events|
          expected = method == :file ? bytes : JSON.parse(bytes)
          assert_equal(expected, state.public_send(method, path, limit: 128))
          assert_equal(2, events[:stats])
          assert_equal(2, events[:opens])
          assert_equal([[2, 129]], events[:reads])
          assert(events[:streams].all?(&:closed?))
        end
      end
    end
  end

  def test_two_safe_replacements_close_each_descriptor_before_success
    with_record do |state, path|
      replace = lambda do |events|
        assert(events[:streams].all?(&:closed?), 'each retry must first close its descriptor')
        replace_record(path, "#{JSON.generate('attempt' => events[:opens])}\n") if events[:opens] <= 2
      end
      with_record_opens(path, before_open: replace) do |events|
        assert_equal({ 'attempt' => 2 }, state.read(path, limit: 128))
        assert_equal(3, events[:stats])
        assert_equal(3, events[:opens])
        assert_equal([[3, 129]], events[:reads])
        assert(events[:streams].all?(&:closed?))
      end
    end
  end

  def test_rename_after_open_returns_the_complete_matching_opened_snapshot
    with_record do |state, path|
      replace = ->(_stream, _events) { replace_record(path, "{\"value\":\"new\"}\n") }
      with_record_opens(path, after_open: replace) do |events|
        assert_equal({ 'value' => 'old' }, state.read(path, limit: 128))
        assert_equal({ 'value' => 'new' }, JSON.parse(File.binread(path)))
        assert_equal(1, events[:stats])
        assert_equal(1, events[:opens])
        assert_equal([[1, 129]], events[:reads])
        assert(events[:streams].all?(&:closed?))
      end
    end
  end

  def test_safe_replacement_churn_stops_after_three_closed_attempts
    with_record do |state, path|
      replace = lambda do |events|
        assert(events[:streams].all?(&:closed?), 'churn must not accumulate open descriptors')
        replace_record(path, "#{JSON.generate('attempt' => events[:opens])}\n")
      end
      with_record_opens(path, before_open: replace) do |events|
        error = assert_raises(KbRuntime::Error) { state.read(path) }
        assert_match(/file changed while opening/, error.message)
        assert_equal(3, events[:stats])
        assert_equal(3, events[:opens])
        assert_empty(events[:reads], 'mismatched snapshots must never be read')
        assert(events[:streams].all?(&:closed?))
      end
    end
  end

  def test_unsafe_named_files_are_refused_without_open_or_retry
    %i[mode size directory symlink].each do |kind|
      with_record do |state, path|
        unsafe_record(path, kind)
        with_record_opens(path) do |events|
          assert_raises(KbRuntime::Error, kind.to_s) { state.file(path, limit: 32) }
          assert_equal(1, events[:stats], kind.to_s)
          assert_equal(0, events[:opens], kind.to_s)
          assert_empty(events[:streams])
        end
      end
    end
  end

  def test_unsafe_opened_replacements_are_refused_without_read_or_retry
    %i[mode size directory].each do |kind|
      with_record do |state, path|
        with_record_opens(path, before_open: ->(_events) { unsafe_record(path, kind) }) do |events|
          assert_raises(KbRuntime::Error, kind.to_s) { state.file(path, limit: 32) }
          assert_equal(1, events[:stats], kind.to_s)
          assert_equal(1, events[:opens], kind.to_s)
          assert_empty(events[:reads])
          assert(events[:streams].all?(&:closed?))
        end
      end
    end
  end

  def test_symlink_replacement_open_failure_is_not_retried
    with_record do |state, path|
      with_record_opens(path, before_open: ->(_events) { unsafe_record(path, :symlink) }) do |events|
        assert_raises(Errno::ELOOP) { state.file(path) }
        assert_equal(1, events[:stats])
        assert_equal(1, events[:opens])
        assert_empty(events[:streams])
      end
    end
  end

  def test_retry_revalidates_symlink_and_non_directory_ancestors
    %i[symlink file].each do |kind|
      with_record do |state, path|
        replace = ->(_events) { replace_record(path, "{}\n") }
        change_parent = lambda do |_stream, _events|
          retained = "#{state.directory}.retained"
          File.rename(state.directory, retained)
          if kind == :symlink
            File.symlink(retained, state.directory)
          else
            File.write(state.directory, 'not a directory', mode: 'wb', perm: 0o600)
          end
        end
        with_record_opens(path, before_open: replace, after_open: change_parent) do |events|
          error = assert_raises(KbRuntime::Error) { state.file(path) }
          assert_match(/state (path|ancestor)/, error.message)
          assert_equal(1, events[:stats], 'retry must reject the ancestor before another lstat')
          assert_equal(1, events[:opens])
          assert_empty(events[:reads])
          assert(events[:streams].all?(&:closed?))
        end
      end
    end
  end

  def test_foreign_uid_in_either_snapshot_is_not_a_retry_condition
    with_record do |state, path|
      original = File.method(:lstat)
      stats = 0
      named = lambda do |name|
        value = original.call(name)
        if name == path
          stats += 1
          value.define_singleton_method(:uid) { Process.uid + 1 }
        end
        value
      end
      File.stub(:lstat, named) do
        File.stub(:open, ->(*) { flunk('foreign named ownership must fail before open') }) do
          assert_raises(KbRuntime::Error) { state.file(path) }
        end
      end
      assert_equal(1, stats)
    end
    with_record do |state, path|
      foreign = lambda do |stream, _events|
        value = stream.stat
        value.define_singleton_method(:uid) { Process.uid + 1 }
        stream.define_singleton_method(:stat) { value }
      end
      with_record_opens(path, after_open: foreign) do |events|
        assert_raises(KbRuntime::Error) { state.file(path) }
        assert_equal(1, events[:stats])
        assert_equal(1, events[:opens])
        assert_empty(events[:reads])
        assert(events[:streams].all?(&:closed?))
      end
    end
  end

  def test_growth_after_matching_fstat_keeps_the_limit_plus_one_bound
    with_record do |state, path|
      grow_on_read = lambda do |stream, _events|
        original = stream.method(:read)
        stream.define_singleton_method(:read) do |length|
          File.open(path, File::WRONLY | File::APPEND) { |writer| writer.write('x' * 64) }
          original.call(length)
        end
      end
      with_record_opens(path, after_open: grow_on_read) do |events|
        error = assert_raises(KbRuntime::Error) { state.file(path, limit: 32) }
        assert_equal('file exceeds size limit', error.message)
        assert_equal([[1, 33]], events[:reads])
        assert_equal(1, events[:stats])
        assert_equal(1, events[:opens])
        assert(events[:streams].all?(&:closed?))
      end
    end
  end

  def test_missing_invalid_json_and_io_errors_are_not_retried
    %i[missing json open read].each do |kind|
      with_record do |state, path|
        File.unlink(path) if kind == :missing
        File.write(path, '{invalid') if kind == :json
        before = kind == :open ? ->(_events) { raise Errno::EACCES, 'injected open refusal' } : nil
        after = kind == :read ? ->(stream, _events) { stream.define_singleton_method(:read) { |_length| raise IOError, 'injected read failure' } } : nil
        with_record_opens(path, before_open: before, after_open: after) do |events|
          expected = { missing: Errno::ENOENT, json: KbRuntime::Error, open: Errno::EACCES, read: IOError }.fetch(kind)
          error = assert_raises(expected, kind.to_s) { state.read(path) }
          assert_match(/invalid JSON/, error.message) if kind == :json
          assert_equal(1, events[:stats], kind.to_s)
          assert_equal(kind == :missing ? 0 : 1, events[:opens], kind.to_s)
          assert(events[:streams].all?(&:closed?))
        end
      end
    end
  end

  def test_atomic_empty_zero_limit_snapshot_remains_valid
    with_record(bytes: '') do |state, path|
      replace = ->(events) { replace_record(path, '') if events[:opens] == 1 }
      with_record_opens(path, before_open: replace) do |events|
        assert_equal('', state.file(path, limit: 0))
        assert_equal(2, events[:stats])
        assert_equal(2, events[:opens])
        assert_equal([[2, 1]], events[:reads])
        assert(events[:streams].all?(&:closed?))
      end
    end
  end

  def test_lock_open_identity_remains_strict_and_closes_on_replacement
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      state.lock('gate', create: true) {}
      path = File.join(state.root, 'locks', 'example.gate.lock')
      original = File.method(:open)
      streams = []
      attempts = 0
      test = self
      opened = lambda do |*args, &block|
        if args[0] == path && args[1] == (File::RDWR | File::NOFOLLOW)
          attempts += 1
          replace_record(path, '')
          stream = original.call(*args)
          streams << stream
          stream.define_singleton_method(:flock) { |_flags| test.flunk('changed lock must not be acquired') }
          stream
        else
          original.call(*args, &block)
        end
      end
      File.stub(:open, opened) do
        error = assert_raises(KbRuntime::Error) { state.lock('gate') { flunk('changed lock was acquired') } }
        assert_equal('lock changed while opening', error.message)
      end
      assert_equal(1, attempts)
      assert(streams.all?(&:closed?))
    ensure
      streams&.each { |stream| stream.close unless stream.closed? }
    end
  end

  private

  def with_record(bytes: "{\"value\":\"old\"}\n")
    Dir.mktmpdir do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
      state.private_directory(state.directory, create: true)
      path = state.path('record.json')
      File.write(path, bytes, mode: 'wb', perm: 0o600)
      yield state, path
    end
  end

  def replace_record(path, bytes, mode: 0o600)
    temporary = "#{path}.replacement"
    File.write(temporary, bytes, mode: 'wb', perm: mode)
    File.chmod(mode, temporary)
    File.rename(temporary, path)
  end

  def unsafe_record(path, kind)
    case kind
    when :mode
      replace_record(path, "{}\n", mode: 0o644)
    when :size
      replace_record(path, 'x' * 33)
    when :directory
      File.unlink(path)
      Dir.mkdir(path, 0o700)
    when :symlink
      target = "#{path}.target"
      File.write(target, "{}\n", mode: 'wb', perm: 0o600)
      File.unlink(path)
      File.symlink(target, path)
    end
  end

  def with_record_opens(path, before_open: nil, after_open: nil)
    events = { stats: 0, opens: 0, streams: [], reads: [] }
    original_lstat = File.method(:lstat)
    original_open = File.method(:open)
    named = lambda do |name|
      events[:stats] += 1 if name == path
      original_lstat.call(name)
    end
    opened = lambda do |*args, &block|
      if args[0] == path && args[1] == (File::RDONLY | File::NOFOLLOW)
        events[:opens] += 1
        attempt = events[:opens]
        before_open&.call(events)
        original_open.call(*args) do |stream|
          events[:streams] << stream
          original_read = stream.method(:read)
          stream.define_singleton_method(:read) do |length|
            events[:reads] << [attempt, length]
            original_read.call(length)
          end
          after_open&.call(stream, events)
          block.call(stream)
        end
      else
        original_open.call(*args, &block)
      end
    end
    File.stub(:lstat, named) { File.stub(:open, opened) { yield events } }
  ensure
    events&.fetch(:streams)&.each { |stream| stream.close unless stream.closed? }
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

  def establish_ssh_trust(_record, deadline:); end
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

  def with_cross_process_holder(state, kind)
    reader, ready = IO.pipe
    release, writer = IO.pipe
    pid = fork do
      reader.close; writer.close
      state.lock(kind, create: true) do
        ready.write('held'); ready.close
        release.read
      end
      exit! 0
    end
    ready.close; release.close
    assert_equal('held', Timeout.timeout(5) { reader.read })
    yield
  ensure
    writer&.close unless writer&.closed?
    reader&.close unless reader&.closed?
    if pid
      Process.wait(pid)
      assert_equal(0, $?.exitstatus)
    end
  end

  def test_all_five_public_lifecycle_requests_refuse_real_gate_contention_before_mutation_or_queued_work
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      requested = config
      begin
        value.start(config: requested, network: 'local', timeout: 5)
        before = retained_files(value)
        builds = value.software.builds
        with_cross_process_holder(value.state, 'gate') do
          %w[start resume update stop reset].each do |action|
            config_path = File.join(directory, 'request-config.json')
            File.write(config_path, JSON.generate(requested), perm: 0o600)
            args = ['--state-root', value.state.root, action, value.state.slug]
            args += ['--config', config_path, '--network', 'local', '--topology', 'single'] if %w[start update].include?(action)
            output, result = IO.pipe
            pid = fork do
              output.close
              KbRuntime::Software.stub(:checkout, value.software) do
                KbRuntime::Engine.stub(:new, value) do
                  code = nil
                  _stdout, error = capture_io { code = KbRuntime::CLI.run(args) }
                  result.write(JSON.generate('code' => code, 'error' => error))
                  result.close
                  exit! code
                end
              end
            end
            result.close
            begin
              response = JSON.parse(Timeout.timeout(5) { output.read })
              assert_equal(75, response.fetch('code'), action)
              assert_includes(response.fetch('error'), 'busy', action)
              Process.wait(pid); pid = nil
              assert_equal(75, $?.exitstatus, action)
              assert_equal(before, retained_files(value), action)
              assert_equal(builds, value.software.builds)
            ensure
              if pid
                Process.kill('TERM', pid)
                Process.wait(pid)
              end
              output.close
            end
          end
        end
        assert_equal(before, retained_files(value), 'released holder must not run queued work')
        value.stop(timeout: 5)
        assert_equal('stopped', value.phase['phase'], 'explicit retry succeeds')
        value.resume(timeout: 5)
        assert(value.status['ready'])
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_operation_contention_releases_the_gate_and_fresh_start_has_no_preparation_effects
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      requested = config
      with_cross_process_holder(value.state, 'operation') do
        assert_raises(KbRuntime::Busy) { value.start(config: requested, network: 'local', timeout: 5) }
        refute(File.exist?(value.state.directory), 'competing start cannot initialize identity')
        assert_equal(0, value.software.builds)
        assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
        value.state.lock('gate', wait: false) { assert(true, 'failed operation acquisition immediately releases gate') }
      end
      begin
        value.start(config: requested, network: 'local', timeout: 5)
        assert(value.status['ready'])
        assert_equal(1, value.software.builds)
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_noncontended_preparation_keeps_ownership_across_long_work
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      original = value.software.method(:build)
      value.software.define_singleton_method(:build) do |*args|
        sleep 0.1
        value.state.lock('gate', wait: false) { raise 'operation lost gate' }
      rescue KbRuntime::Busy
        original.call(*args)
      end
      begin
        value.start(config: config, network: 'local', timeout: 5)
        assert(value.status['ready'])
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
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

  # Only the existing synthetic runner consumes shutdown_fixture. The real
  # Engine, control peer, receipts, locks and filesystem descriptors stay real.
  def with_shutdown_fixture(mode: 'residual')
    Dir.mktmpdir('kb-handoff-', '/tmp') do |directory|
      server = UNIXServer.new(File.join(directory, 'barrier.sock'))
      File.chmod(0o600, server.path)
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      input = config.merge('shutdown_fixture' => { 'mode' => mode, 'barrier' => server.path })
      context = { value: value, server: server, requested: false, released: false, descriptors: [] }
      value.start(config: input, network: 'local', timeout: 5)
      context[:record] = value.launch
      context[:runner] = value.process_record(context[:record]).fetch('runner')
      context[:initial_children] = value.process_record(context[:record]).fetch('children')
      yield context
    ensure
      if context && context[:record]
        if !context[:requested] && value.live?(context[:record])
          begin_shutdown(context)
        end
        if context[:requested] && !context[:peer] && value.live?(context[:record])
          context[:peer] = Timeout.timeout(5) { server.accept }
          JSON.parse(Timeout.timeout(5) { context[:peer].gets })
        end
        finish_shutdown(context) if context[:peer] && !context[:released]
        context[:worker]&.value
        Timeout.timeout(5) { Thread.pass until KbRuntime::ProcessIdentity.gone?(context[:runner]) }
      end
      context&.dig(:peer)&.close unless context&.dig(:peer)&.closed?
      server&.close unless server&.closed?
    end
  end

  def capture_shutdown_descriptors(context)
    original = File.method(:open)
    opened = lambda do |*args, &block|
      descriptor = original.call(*args, &block)
      if args[1].is_a?(Integer) && (args[1] & (0x200000 | 0x10000)) != 0
        context[:descriptors] << descriptor
      end
      descriptor
    end
    File.stub(:open, opened) { yield }
  end

  def begin_shutdown(context, timeout: 5)
    context[:requested] = true
    context[:worker] = Thread.new do
      begin
        capture_shutdown_descriptors(context) { context[:value].stop(timeout:) }
        nil
      rescue StandardError => error
        error
      end
    end
    context[:peer] = Timeout.timeout(5) { context[:server].accept }
    response = JSON.parse(Timeout.timeout(5) { context[:peer].gets })
    assert_equal({ 'stage' => 'after-response', 'run_id' => context[:record]['run_id'] }, response)
    assert_equal(2, context[:descriptors].length)
    context[:descriptors].each { |descriptor| refute(descriptor.closed?); assert(descriptor.close_on_exec?) }
  end

  def finish_shutdown(context)
    context[:released] = true
    context[:peer].puts('continue')
    terminal = JSON.parse(Timeout.timeout(5) { context[:peer].gets })
    assert_equal('finished', terminal['stage'])
    context[:peer].close
    result = context[:worker]&.value
    Timeout.timeout(5) { Thread.pass until KbRuntime::ProcessIdentity.gone?(context[:runner]) }
    context[:descriptors].each { |descriptor| assert(descriptor.closed?, 'operation-local proof descriptor must close') }
    result
  end

  def test_authenticated_lone_residual_is_retired_only_after_complete_exit_and_reaches_stopped
    with_shutdown_fixture do |context|
      value, record = context.values_at(:value, :record)
      begin_shutdown(context)
      refute(value.gone?(record))
      assert_equal(['control.sock'], Dir.children(record['socket_dir']))
      assert_equal(1, Dir.glob(File.join(value.resources.root, '*.json')).length)
      identities = context[:descriptors].map { |descriptor| [descriptor.fileno, descriptor.stat.dev, descriptor.stat.ino] }
      program = 'require "json"; values = JSON.parse(ARGV.fetch(0)); exit(values.any? { |fd, dev, ino| begin; s = IO.for_fd(fd).stat; [s.dev, s.ino] == [dev, ino]; rescue Errno::EBADF; false; end } ? 1 : 0)'
      _out, _err, status = Open3.capture3(RbConfig.ruby, '-e', program, JSON.generate(identities), close_others: false)
      assert(status.success?, 'an unrelated exec child must not inherit either proof inode')
      assert_nil(finish_shutdown(context))
      assert(value.gone?(record))
      assert_equal('stopped', value.phase['phase'])
      refute(File.exist?(record['socket_dir']))
      assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
    end
  end

  def test_normal_runner_removal_uses_the_same_strict_empty_namespace_path
    with_shutdown_fixture(mode: 'normal') do |context|
      begin_shutdown(context)
      assert_nil(finish_shutdown(context))
      assert_equal('stopped', context[:value].phase['phase'])
      refute(File.exist?(context[:record]['socket_dir']))
    end
  end

  def test_handoff_checks_every_terminal_child_even_when_the_recorded_children_grow
    with_shutdown_fixture(mode: 'growing') do |context|
      begin_shutdown(context)
      proof = context[:value].process_record(context[:record])
      assert_equal(1, context[:initial_children].length)
      assert_equal(2, proof['children'].length)
      assert_equal(context[:initial_children], proof['children'].first(1))
      assert_equal(context[:runner], proof['runner'])
      refute(context[:value].gone?(context[:record]))
      assert_nil(finish_shutdown(context))
      terminal = context[:value].process_record(context[:record])
      assert_equal(proof['children'], terminal['children'])
      assert(terminal['children'].all? { |child| KbRuntime::ProcessIdentity.gone?(child) })
      assert_equal('stopped', context[:value].phase['phase'])
    end
  end

  def test_unknown_neighbor_refuses_before_either_entry_is_unlinked_after_claim_release
    with_shutdown_fixture do |context|
      begin_shutdown(context)
      directory = context[:record]['socket_dir']
      neighbor = File.join(directory, 'unrecognized')
      File.write(neighbor, 'retain', perm: 0o600)
      error = finish_shutdown(context)
      assert_instance_of(KbRuntime::Error, error)
      assert_match(/unrecognized retained socket contents/, error.message)
      assert_equal(%w[control.sock unrecognized], Dir.children(directory).sort)
      assert_equal('retain', File.read(neighbor))
      refute_equal('stopped', context[:value].phase['phase'])
      assert_empty(Dir.glob(File.join(context[:value].resources.root, '*.json')), 'late cleanup refusal follows claim release')
    end
  end

  def test_socket_name_replacement_cannot_reuse_the_pinned_original_inode
    with_shutdown_fixture do |context|
      begin_shutdown(context)
      path = File.join(context[:record]['socket_dir'], 'control.sock')
      retained = File.join(File.dirname(context[:server].path), 'original.sock')
      original = File.lstat(path)
      File.rename(path, retained)
      replacement = UNIXServer.new(path)
      File.chmod(0o600, path)
      assert_equal(original.ino, File.lstat(retained).ino)
      assert_equal(original.ino, context[:descriptors].last.stat.ino)
      refute_equal(original.ino, File.lstat(path).ino)
      error = finish_shutdown(context)
      assert_instance_of(KbRuntime::Error, error)
      assert_match(/control socket changed/, error.message)
      assert(File.socket?(path)); assert(File.socket?(retained))
      refute_equal('stopped', context[:value].phase['phase'])
    ensure
      replacement&.close
    end
  end

  def test_parent_replacement_preserves_original_and_replacement_namespaces
    with_shutdown_fixture do |context|
      begin_shutdown(context)
      directory = context[:record]['socket_dir']
      retained = "#{directory}-original"
      original = File.lstat(directory)
      File.rename(directory, retained)
      Dir.mkdir(directory, 0o700)
      replacement = UNIXServer.new(File.join(directory, 'control.sock'))
      File.chmod(0o600, File.join(directory, 'control.sock'))
      assert_equal(original.ino, context[:descriptors].first.stat.ino)
      error = finish_shutdown(context)
      assert_instance_of(KbRuntime::Error, error)
      assert_match(/socket directory changed/, error.message)
      [directory, retained].each { |path| assert_equal(['control.sock'], Dir.children(path)) }
      refute_equal('stopped', context[:value].phase['phase'])
    ensure
      replacement&.close
    end
  end

  def test_unchanged_terminal_launch_and_runner_are_required_even_after_accepted_ack
    %w[launch runner].each do |which|
      with_shutdown_fixture do |context|
        begin_shutdown(context)
        record = context[:record]
        if which == 'launch'
          path = context[:value].state.path("launch-#{record['run_id']}.json")
          context[:value].state.write(path, record.merge('fixture_change' => true))
        else
          original_record = context[:value].method(:process_record)
          runner = context[:runner].merge('start_ticks' => 'changed')
          context[:value].define_singleton_method(:process_record) do |launch|
            proof = original_record.call(launch)
            proof['complete'] ? proof.merge('runner' => runner) : proof
          end
        end
        error = finish_shutdown(context)
        assert_instance_of(KbRuntime::Error, error)
        assert_match(/unchanged complete exit proof/, error.message)
        assert(File.socket?(File.join(record['socket_dir'], 'control.sock')))
        refute_equal('stopped', context[:value].phase['phase'])
      end
    end
  end

  def test_missing_ack_and_early_eof_grant_no_residual_retirement
    %w[bad-ack wrong-ack-run early-eof].each do |mode|
      with_shutdown_fixture(mode:) do |context|
        # No usable handoff is returned, so its proof FDs close before the
        # fixture's shutdown barrier is released.
        context[:requested] = true
        error = capture_shutdown_descriptors(context) { assert_raises(KbRuntime::Error) { context[:value].stop(timeout: 5) } }
        assert_match(/invalid runner control response/, error.message)
        context[:peer] = Timeout.timeout(5) { context[:server].accept }
        JSON.parse(Timeout.timeout(5) { context[:peer].gets })
        context[:descriptors].each { |descriptor| assert(descriptor.closed?) }
        finish_shutdown(context)
        assert_raises(KbRuntime::Error) { context[:value].stop(timeout: 5) }
        assert(File.socket?(File.join(context[:record]['socket_dir'], 'control.sock')))
        refute_equal('stopped', context[:value].phase['phase'])
      end
    end
  end

  def test_incomplete_exit_receipt_cannot_release_claims_or_retire_the_socket
    with_shutdown_fixture(mode: 'incomplete') do |context|
      begin_shutdown(context, timeout: 2)
      error = finish_shutdown(context)
      assert_instance_of(KbRuntime::Error, error)
      assert_match(/owned shutdown incomplete/, error.message)
      refute(context[:value].gone?(context[:record]))
      assert_equal(false, context[:value].process_record(context[:record])['complete'])
      assert_equal(1, Dir.glob(File.join(context[:value].resources.root, '*.json')).length)
      assert(File.socket?(File.join(context[:record]['socket_dir'], 'control.sock')))
    end
  end

  def test_live_retry_must_authenticate_a_new_request_after_invalid_ack
    with_shutdown_fixture(mode: 'retry') do |context|
      error = capture_shutdown_descriptors(context) { assert_raises(KbRuntime::Error) { context[:value].stop(timeout: 5) } }
      assert_match(/invalid runner control response/, error.message)
      assert(context[:value].live?(context[:record]))
      context[:descriptors].each { |descriptor| assert(descriptor.closed?) }
      context[:descriptors].clear
      begin_shutdown(context)
      assert_nil(finish_shutdown(context))
      assert_equal('stopped', context[:value].phase['phase'])
    end
  end

  def test_interrupted_controller_loses_handoff_and_dead_residual_retry_refuses
    %w[residual normal].each do |mode|
      with_shutdown_fixture(mode:) do |context|
        context[:requested] = true
        ack_reader, ack_writer = IO.pipe
        controller = fork do
          context[:server].close
          ack_reader.close
          control = context[:value].method(:control)
          context[:value].define_singleton_method(:control) do |record, command|
            handoff = control.call(record, command)
            ack_writer.write('accepted'); ack_writer.close
            handoff
          end
          context[:value].stop(timeout: 5)
          exit! 0
        end
        ack_writer.close
        context[:peer] = Timeout.timeout(5) { context[:server].accept }
        event = JSON.parse(Timeout.timeout(5) { context[:peer].gets })
        assert_equal('after-response', event['stage'])
        assert_equal('accepted', Timeout.timeout(5) { ack_reader.read }, 'controller received the valid acknowledgement')
        # This unreaped PID is solely our forked controller; no runner or group
        # receives a signal. Kernel close discards its descriptor authority.
        Process.kill('KILL', controller)
        Process.wait(controller)
        controller = nil
        assert_equal(Signal.list.fetch('KILL'), $?.termsig)
        finish_shutdown(context)
        assert(context[:value].gone?(context[:record]))
        if mode == 'residual'
          assert_raises(KbRuntime::Error) { context[:value].stop(timeout: 5) }
          assert(File.socket?(File.join(context[:record]['socket_dir'], 'control.sock')))
          refute_equal('stopped', context[:value].phase['phase'])
        else
          context[:value].stop(timeout: 5)
          assert_equal('stopped', context[:value].phase['phase'])
          refute(File.exist?(context[:record]['socket_dir']))
        end
      ensure
        ack_reader&.close unless ack_reader&.closed?
        ack_writer&.close unless ack_writer&.closed?
        if controller
          Process.kill('KILL', controller)
          Process.wait(controller)
        end
      end
    end
  end

  def test_unsafe_socket_and_directory_metadata_refuse_before_a_request_with_closed_descriptors
    %w[socket-mode directory-mode file symlink uid].each do |wrong|
      with_shutdown_fixture do |context|
        value, record = context.values_at(:value, :record)
        path = File.join(record['socket_dir'], 'control.sock')
        retained = "#{path}-retained"
        original_stat = File.method(:lstat)
        case wrong
        when 'socket-mode' then File.chmod(0o666, path)
        when 'directory-mode' then File.chmod(0o755, record['socket_dir'])
        when 'file', 'symlink'
          File.rename(path, retained)
          wrong == 'file' ? File.write(path, 'retain', perm: 0o600) : File.symlink(retained, path)
        end
        named_stat = lambda do |name|
          stat = original_stat.call(name)
          if wrong == 'uid' && name == path
            stat.define_singleton_method(:uid) { Process.uid + 1 }
          end
          stat
        end
        File.stub(:lstat, named_stat) do
          capture_shutdown_descriptors(context) { assert_raises(KbRuntime::Error) { value.stop(timeout: 5) } }
        end
        assert(value.live?(record), 'unsafe paths must not send shutdown')
        assert_equal(1, Dir.glob(File.join(value.resources.root, '*.json')).length)
        context[:descriptors].each { |descriptor| assert(descriptor.closed?) }
      ensure
        if %w[file symlink].include?(wrong) && retained && File.socket?(retained)
          File.unlink(path)
          File.rename(retained, path)
        end
        File.chmod(0o600, path) if path && File.socket?(path)
        File.chmod(0o700, record['socket_dir']) if record && File.directory?(record['socket_dir'])
        context[:descriptors].clear if context
      end
    end
  end

  def test_same_uid_foreign_peer_and_wrong_launch_refuse_without_sending_stop
    with_shutdown_fixture do |context|
      value, record = context.values_at(:value, :record)
      path = File.join(record['socket_dir'], 'control.sock')
      retained = "#{path}-retained"
      File.rename(path, retained)
      reader, ready = IO.pipe
      foreign = fork do
        reader.close
        server = UNIXServer.new(path)
        File.chmod(0o600, path)
        ready.write('ready'); ready.close
        peer = server.accept
        request = peer.gets
        peer.close; server.close
        exit!(request.nil? ? 0 : 1)
      end
      ready.close
      assert_equal('ready', Timeout.timeout(5) { reader.read })
      error = capture_shutdown_descriptors(context) { assert_raises(KbRuntime::Error) { value.stop(timeout: 5) } }
      assert_match(/foreign runner control peer/, error.message)
      Process.wait(foreign)
      foreign = nil
      assert_equal(0, $?.exitstatus, 'foreign peer must receive no request')
      assert(value.live?(record))
      context[:descriptors].each { |descriptor| assert(descriptor.closed?) }
      File.unlink(path); File.rename(retained, path)
      context[:descriptors].clear
      value.state.transaction(wait: false) do
        assert_raises(KbRuntime::Error) { value.send(:control, record.merge('run_id' => SecureRandom.uuid), 'stop') }
      end
      assert(value.live?(record))
    ensure
      reader&.close unless reader&.closed?
      ready&.close unless ready&.closed?
      if foreign
        Process.kill('KILL', foreign)
        Process.wait(foreign)
      end
      if retained && File.socket?(retained)
        File.unlink(path) if File.socket?(path)
        File.rename(retained, path)
      end
    end
  end

  def test_shared_ssh_discovery_deadline_reaches_existing_live_verification_once
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      original_credentials = value.method(:initialize_credentials)
      value.define_singleton_method(:initialize_credentials) do |input|
        credentials = original_credentials.call(input)
        File.write(File.join(credentials, 'known_hosts'), '')
        credentials
      end
      attempts = 0
      verifications = 0
      deadlines = []
      discovered_key = nil
      value.define_singleton_method(:establish_ssh_trust) do |record, deadline:|
        KbRuntime::Engine.instance_method(:establish_ssh_trust).bind_call(self, record, deadline:)
      end
      original_verify = value.method(:verify_live)
      value.define_singleton_method(:verify_live) do |record|
        verifications += 1
        original_verify.call(record)
      end
      scan = lambda do |endpoint, timeout:, deadline:|
        attempts += 1
        deadlines << deadline
        assert_operator(timeout, :>=, 1)
        assert_operator(timeout, :<=, 5)
        assert_equal('verifying', value.phase['phase'])
        output = if attempts == 1
                   ''
                 else
                   wire = [11].pack('N') + 'ssh-ed25519' + [32].pack('N') + 'k' * 32
                   "[#{endpoint['host']}]:#{endpoint['port']} ssh-ed25519 #{Base64.strict_encode64(wire)}"
                 end
        discovered_key = output unless output.empty?
        { stdout: output, stderr: '', exitstatus: output.empty? ? 1 : 0,
          termsig: nil, deadline: false, truncated: false }
      end
      begin
        value.stub(:ssh_keyscan, scan) { value.start(config: config, network: 'local', timeout: 5) }
        assert_equal(2, attempts)
        assert_equal(1, deadlines.uniq.length)
        assert_equal(1, verifications)
        assert_equal(1, value.software.builds)
        assert(value.status['ready'])
        assert_equal("#{discovered_key}\n", value.state.file(File.join(value.state.path('credentials'), 'known_hosts')))
        value.stop(timeout: 5)
        assert_equal(1, verifications)
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json')) && value.phase['phase'] != 'stopped'
      end
    end
  end

  def test_process_receipt_rename_during_readiness_does_not_replay_prepare_build_or_spawn
    Dir.mktmpdir do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      preparations = 0
      spawns = 0
      renamed = false
      streams = []
      original_prepare = value.software.method(:prepare)
      value.software.define_singleton_method(:prepare) do |*args, **options|
        preparations += 1
        original_prepare.call(*args, **options)
      end
      original_spawn = Process.method(:spawn)
      spawn = lambda do |*args, **options|
        spawns += 1
        original_spawn.call(*args, **options)
      end
      original_open = File.method(:open)
      opened = lambda do |*args, &block|
        process_record = args[0].is_a?(String) && File.dirname(args[0]) == value.state.directory &&
          /\Aprocesses-[0-9a-f-]+\.json\z/.match?(File.basename(args[0])) &&
          args[1] == (File::RDONLY | File::NOFOLLOW)
        if process_record
          unless renamed
            assert_equal('starting', value.phase['phase'])
            path = args[0]
            before = File.stat(path)
            temporary = "#{path}.readiness-replacement"
            File.write(temporary, File.binread(path), mode: 'wb', perm: 0o600)
            File.rename(temporary, path)
            refute_equal(before.ino, File.stat(path).ino)
            renamed = true
          end
          original_open.call(*args) do |stream|
            streams << stream
            block.call(stream)
          end
        else
          original_open.call(*args, &block)
        end
      end
      begin
        Process.stub(:spawn, spawn) do
          File.stub(:open, opened) { value.start(config: config, network: 'local', timeout: 5) }
        end
        assert(renamed, 'the readiness reader must encounter the actual atomic replacement')
        assert(streams.all?(&:closed?))
        assert_equal(1, preparations)
        assert_equal(1, value.software.builds)
        assert_equal(1, spawns)
        assert_equal(1, Dir.glob(File.join(value.state.directory, 'launch-*.json')).length)
        assert_equal(1, Dir.glob(File.join(value.state.directory, 'spawn-*.json')).length)
        record = value.launch
        assert_equal(1, value.process_record(record).fetch('children').length)
        assert(value.status['ready'])
        value.stop(timeout: 5)
        assert_equal('stopped', value.phase['phase'])
        assert(value.process_record(record).fetch('complete'))
        assert(value.gone?(record))
        assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
        assert_equal(1, preparations)
        assert_equal(1, value.software.builds)
        assert_equal(1, spawns)
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json')) && value.phase['phase'] != 'stopped'
        streams.each { |stream| stream.close unless stream.closed? }
      end
    end
  end

  def test_public_stop_reads_retained_g4_schema_two_launch_without_selecting_software
    original_runtime = ENV['XDG_RUNTIME_DIR']
    Dir.mktmpdir('kb-g4-', '/tmp') do |directory|
      runtime = File.join(directory, 'runtime')
      Dir.mkdir(runtime, 0o700)
      ENV['XDG_RUNTIME_DIR'] = runtime
      value = engine(File.join(directory, 'state'), File.join(runtime, 'vpsfree-kb', 'reservations'))
      value.software.metadata['revision'] = 'ab09bd437b310f57e4ff2453ec0432555d85eaca'
      begin
        value.start(config: config, network: 'local', timeout: 5)
        record = value.launch
        assert_equal(2, value.state.identity.fetch('schema'))
        assert_equal('ab09bd437b310f57e4ff2453ec0432555d85eaca', record.fetch('source').fetch('revision'))
        retained = [value.state.path('identity.json'), value.state.path("launch-#{record['run_id']}.json"),
          value.state.path("artifact-#{record['artifact_id']}.json")].to_h { |path| [path, File.binread(path)] }
        credentials = KbRuntime::Software.credentials_identity(value.state.path('credentials'))
        no_source = ->(*) { flunk('public stop must validate retained launch without selecting guest software') }
        output, error = capture_io do
          KbRuntime::Software.stub(:checkout, no_source) do
            KbRuntime::Software.stub(:new, no_source) do
              assert_equal(0, KbRuntime::CLI.run(['--state-root', value.state.root, 'stop', value.state.slug, '--timeout', '5']))
            end
          end
        end
        assert_empty(output)
        assert_empty(error)
        assert_equal('stopped', value.phase['phase'])
        assert(value.process_record(record).fetch('complete'))
        assert(value.gone?(record), 'ordinary stop must prove runner and child exit')
        assert_empty(Dir.glob(File.join(value.resources.root, '*.json')))
        assert_equal(retained, retained.keys.to_h { |path| [path, File.binread(path)] })
        assert_equal(credentials, KbRuntime::Software.credentials_identity(value.state.path('credentials')))
        assert_equal(1, value.software.builds)
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json')) && value.phase['phase'] != 'stopped'
      end
    end
  ensure
    ENV['XDG_RUNTIME_DIR'] = original_runtime
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

  def test_missing_ready_marker_denies_status_connection_update_and_capture_without_effects
    Dir.mktmpdir('kb-readiness-', '/tmp') do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      begin
        requested = config
        value.start(config: requested, network: 'local', timeout: 5)
        record = value.launch
        connection = value.state.file(value.state.path('connection.json'))
        File.unlink(value.state.path("ready-#{record['run_id']}.json"))
        before = retained_files(value)
        assert(value.live?(record))
        refute(value.ready?(record))
        assert_equal('ready', value.phase['phase'], 'signal-origin drain may retain the ready phase')
        refute(value.status['ready'])
        assert_raises(KbRuntime::Error) { value.connection }
        update_error = assert_raises(KbRuntime::Error) { value.update(config: requested, topology: 'single', network: 'local', timeout: 5) }
        assert_match(/live ready predecessor/, update_error.message)
        error = assert_raises(KbRuntime::Error) do
          value.capture_lease(instance_id: record['instance_id'], run_id: record['run_id'],
            artifact_id: record['artifact_id'], artifact_sha256: record['artifact_sha256'],
            descriptor_sha256: Digest::SHA256.hexdigest(connection), input: StringIO.new, output: StringIO.new)
        end
        assert_match(/not ready/, error.message)
        assert_equal(before, retained_files(value))
        assert_equal(1, value.software.builds)
      ensure
        # This synthetic runner permits a marker already withdrawn by the test.
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_foreign_and_unsafe_ready_markers_keep_their_strict_refusal
    Dir.mktmpdir('kb-readiness-', '/tmp') do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      begin
        value.start(config: config, network: 'local', timeout: 5)
        record = value.launch
        path = value.state.path("ready-#{record['run_id']}.json")
        marker = value.state.read(path)
        %w[schema instance_id run_id artifact_id artifact_sha256].each do |key|
          value.state.write(path, marker.merge(key => key == 'schema' ? 2 : 'foreign'))
          before = retained_files(value)
          assert_raises(KbRuntime::Error) { value.status }
          assert_raises(KbRuntime::Error) { value.connection }
          assert(value.live?(record))
          assert_equal(before, retained_files(value))
        end
        value.state.write(path, marker)
        File.chmod(0o644, path)
        assert_raises(KbRuntime::Error) { value.ready?(record) }
        File.chmod(0o600, path)
        value.state.write(path, marker)
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_readiness_loss_cancels_an_acquired_capture_and_prevents_late_handshake
    Dir.mktmpdir('kb-readiness-', '/tmp') do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      begin
        value.start(config: config, network: 'local', timeout: 5)
        record = value.launch
        marker = value.state.path("ready-#{record['run_id']}.json")
        original = value.state.read(marker)
        connection = value.state.file(value.state.path('connection.json'))
        input, writer = IO.pipe
        output_reader, output = IO.pipe
        lease = Thread.new do
          value.capture_lease(instance_id: record['instance_id'], run_id: record['run_id'],
            artifact_id: record['artifact_id'], artifact_sha256: record['artifact_sha256'],
            descriptor_sha256: Digest::SHA256.hexdigest(connection), input:, output:)
        rescue KbRuntime::Error => error
          error
        end
        assert_equal(record['run_id'], JSON.parse(Timeout.timeout(5) { output_reader.gets })['run_id'])
        File.unlink(marker)
        error = Timeout.timeout(5) { lease.value }
        assert_instance_of(KbRuntime::Error, error)
        assert_match(/readiness lost/, error.message)
        assert(value.live?(record))
        refute(value.status['ready'])
        value.state.write(marker, original)
        verify = value.method(:verify_live)
        value.define_singleton_method(:verify_live) do |current|
          verify.call(current)
          File.unlink(marker)
        end
        handshake = StringIO.new
        assert_raises(KbRuntime::Error) do
          value.capture_lease(instance_id: record['instance_id'], run_id: record['run_id'],
            artifact_id: record['artifact_id'], artifact_sha256: record['artifact_sha256'],
            descriptor_sha256: Digest::SHA256.hexdigest(connection), input: StringIO.new, output: handshake)
        end
        assert_empty(handshake.string)
      ensure
        writer&.close unless writer&.closed?
        lease&.join
        [input, output_reader, output].compact.each { |stream| stream.close unless stream.closed? }
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
      end
    end
  end

  def test_marker_withdrawn_during_initial_attestation_never_reports_ready
    Dir.mktmpdir('kb-readiness-', '/tmp') do |directory|
      value = engine(File.join(directory, 'state'), File.join(directory, 'claims'))
      verify = value.method(:verify_live)
      value.define_singleton_method(:verify_live) do |record|
        verify.call(record)
        File.unlink(state.path("ready-#{record['run_id']}.json"))
      end
      begin
        failure = assert_raises(KbRuntime::Error) { value.start(config: config, network: 'local', timeout: 5) }
        assert_match(/readiness withdrawn/, failure.message)
        refute(value.status['ready'])
        assert(value.live?(value.launch))
        assert_equal(1, value.software.builds)
        assert_equal(1, Dir.glob(File.join(value.state.directory, 'launch-*.json')).length)
        refute(File.exist?(value.state.path('connection.json')))
      ensure
        value.stop(timeout: 5) if File.exist?(value.state.path('phase.json'))
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

class LifecycleCompletionFormattingTest < Minitest::Test
  def test_start_resume_update_use_completed_descriptor_without_fresh_status_lock
    descriptor = { 'instance_id' => SecureRandom.uuid, 'run_id' => SecureRandom.uuid }
    %w[start resume update].each do |action|
      Dir.mktmpdir do |directory|
        state = KbRuntime::State.new(File.join(directory, 'state'), 'example')
        state.transaction(create: true) { state.initialize_identity }
        config = File.join(directory, 'config.json')
        File.write(config, JSON.generate('local' => { 'multicastPort' => 10000 }, 'topologies' => { 'single' => [] }))
        entered, release = Queue.new, Queue.new
        holder = nil
        engine = Object.new
        engine.define_singleton_method(action) do |**_|
          holder = Thread.new { state.lock('gate') { entered << true; release.pop } }
          entered.pop
          descriptor
        end
        engine.define_singleton_method(:status) { raise KbRuntime::Busy, 'post-success gate belongs to capture' }
        KbRuntime::Software.stub(:checkout, nil) do
          KbRuntime::Engine.stub(:new, engine) do
            args = ['--state-root', state.root, action, 'example']
            args += ['--network', 'local', '--config', config] unless action == 'resume'
            output, = capture_io { assert_equal(0, KbRuntime::CLI.run(args)) }
            assert_equal({ 'schema' => 2, 'found' => true, 'state' => 'ready', 'ready' => true,
              'instance_id' => descriptor['instance_id'], 'run_id' => descriptor['run_id'] }, JSON.parse(output))
          end
        end
      ensure
        release << true if holder
        holder&.join
      end
    end
  end
end
