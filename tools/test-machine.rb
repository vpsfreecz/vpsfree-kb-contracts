# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'timeout'
require_relative '../cluster/lib/kb_machine'
require_relative '../cluster/lib/kb_source'
require_relative '../cluster/lib/kb_runtime'

class PreparedMachineTest < Minitest::Test
  def configuration(image, suffix)
    { 'spin' => 'nixos', 'qemu' => '/not-executed', 'virtiofsd' => '/not-executed',
      'memory' => 64, 'cpus' => 1, 'cpu' => { 'cores' => 1, 'threads' => 1, 'sockets' => 1 },
      'kernel' => "/candidate/#{suffix}/kernel", 'initrd' => "/candidate/#{suffix}/initrd", 'toplevel' => "/candidate/#{suffix}/system",
      'diskImage' => image, 'disks' => [{ 'device' => 'services-data.img', 'type' => 'file', 'size' => '1M' }],
      'networks' => [{ 'type' => 'socket', 'mcast' => { 'address' => '230.0.0.1', 'port' => 31001 } }] }
  end

  def with_machine
    Dir.mktmpdir('kb-machine-') do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'driver-test')
      identity = state.transaction(create: true) { state.initialize_identity }
      disks = state.path('disks')
      sockets = state.path('sockets')
      state.private_directory(disks, create: true)
      state.private_directory(sockets, create: true)
      image = File.join(directory, 'initial.img')
      File.write(image, 'initial root sentinel')
      config = configuration(image, 'old')
      artifact = { 'instance_id' => identity['instance_id'], 'artifact_id' => SecureRandom.uuid,
        'layout' => KbRuntime::Software.layout('machines' => { 'services' => config }) }
      machine = KbRuntime::NixosMachine.new('services', OsVm::MachineConfig.from_config(config), disks, sockets).bind_preparation(state, artifact)
      begin
        yield state, artifact, machine, config, disks, sockets
      ensure
        machine.finalize
      end
    end
  end

  def test_exact_upstream_driver_keeps_root_and_data_but_boots_new_kernel_init_and_toplevel
    with_machine do |state, artifact, machine, config, disks, sockets|
      machine.send(:prepare_disks)
      root = File.join(disks, 'services-root.img')
      data = File.join(disks, 'services-data.img')
      initial = [root, data].to_h { |path| [path, File.stat(path).ino] }
      File.open(data, 'r+b') { |file| file.write('data sentinel') }
      proof = state.read(state.path('disks-services.json'))
      assert_equal(config['diskImage'], proof['initial_images']['root'])
      candidate_image = File.join(File.dirname(config['diskImage']), 'candidate.img')
      File.write(candidate_image, 'replacement would lose the sentinel')
      replacement = config.merge('kernel' => '/candidate/new/kernel', 'initrd' => '/candidate/new/initrd',
        'toplevel' => '/candidate/new/system', 'diskImage' => candidate_image)
      newer = artifact.merge('artifact_id' => SecureRandom.uuid)
      next_machine = KbRuntime::NixosMachine.new('services', OsVm::MachineConfig.from_config(replacement), disks, sockets).bind_preparation(state, newer)
      begin
        next_machine.send(:prepare_disks)
        assert_equal(initial, [root, data].to_h { |path| [path, File.stat(path).ino] })
        assert_equal('initial root sentinel', File.read(root))
        assert_equal('data sentinel', File.read(data, 13))
        command = next_machine.send(:qemu_command)
        assert_equal('/candidate/new/kernel', command[command.index('-kernel') + 1])
        assert_equal('/candidate/new/initrd', command[command.index('-initrd') + 1])
        assert_includes(command[command.index('-append') + 1], 'init=/candidate/new/system/init')
        assert_includes(command, "socket,id=net0,mcast=230.0.0.1:31001")
      ensure
        next_machine.finalize
      end
    end
  end

  def test_missing_retained_root_is_not_recreated
    with_machine do |_state, _artifact, machine, _config, disks, _sockets|
      machine.send(:prepare_disks)
      root = File.join(disks, 'services-root.img')
      File.unlink(root)
      assert_raises(Errno::ENOENT) { machine.send(:prepare_disks) }
      refute(File.exist?(root))
    end
  end

  def test_unrecorded_root_is_not_adopted_or_replaced
    with_machine do |_state, _artifact, machine, _config, disks, _sockets|
      root = File.join(disks, 'services-root.img')
      File.write(root, 'foreign root')
      assert_raises(KbRuntime::Error) { machine.send(:prepare_disks) }
      assert_equal('foreign root', File.read(root))
    end
  end

  def test_explicit_multicast_port_survives_separate_osvm_processes
    program = <<~RUBY
      require 'json'
      require 'osvm'
      network = OsVm::MachineConfig::SocketNetwork.new(0, {
        'type' => 'socket', 'mcast' => { 'address' => '230.0.0.1', 'port' => Integer(ARGV.fetch(0)) }
      })
      puts JSON.generate(network.qemu_options)
    RUBY
    [31001, 31002].each do |port|
      out, err, status = Open3.capture3(RbConfig.ruby, '-e', program, port.to_s)
      assert(status.success?, err)
      assert_includes(JSON.parse(out), "socket,id=net0,mcast=230.0.0.1:#{port}")
    end
  end
end

class RunnerSessionTest < Minitest::Test
  def test_runner_survives_controlled_parent_exit_with_distinct_session_and_no_guard_fds
    with_runner do |context|
      with_controller(context) do |pid, input, output|
        observe_runner(context, output, pid)
        input.write('.')
        input.flush
        status = Process.waitpid2(pid).last
        context[:controller_reaped] = true
        assert(status.success?)
        assert_retained_runner(context)
        shutdown(context)
      end
    end
  end

  def test_test_owned_parent_group_signal_does_not_end_the_runner_session
    with_runner do |context|
      with_controller(context) do |pid, _input, output|
        observe_runner(context, output, pid)
        assert_equal(pid, Process.getpgid(pid))
        refute_equal(Process.getpgrp, pid)
        Process.kill('TERM', -pid)
        status = Process.waitpid2(pid).last
        context[:controller_reaped] = true
        assert_equal(Signal.list.fetch('TERM'), status.termsig)
        assert_retained_runner(context)
        shutdown(context)
      end
    end
  end

  def test_already_own_session_leader_does_not_call_setsid_again
    with_runner(mode: 'own-session') do |context|
      with_controller(context) do |pid, input, output|
        observe_runner(context, output, pid)
        input.write('.')
        input.flush
        status = Process.waitpid2(pid).last
        context[:controller_reaped] = true
        assert(status.success?)
        assert_retained_runner(context)
        shutdown(context)
      end
    end
  end

  def test_setsid_failure_refuses_before_machine_creation_or_live_tuple_publication
    with_runner(mode: 'session-failure') do |context|
      out, error, status = Open3.capture3(*runner_argv(context))
      File.write(context[:log], out, mode: 'wb', perm: 0o600)
      File.write(context[:error], error, mode: 'wb', perm: 0o600)
      refute(status.success?)
      assert_empty(out)
      assert_includes(error, 'injected setsid refusal')
      refute(File.exist?(context[:marker]))
      refute(File.exist?(context[:state].path("processes-#{context[:record]['run_id']}.json")))
      refute(File.exist?(context[:state].path("ready-#{context[:record]['run_id']}.json")))
      assert_equal('starting', context[:engine].phase['phase'])
      assert_equal(context[:claims], Dir.glob(File.join(context[:engine].resources.root, '*.json')).to_h { |path| [path, File.binread(path)] })
    end
  end

  def test_public_stop_quiesces_the_real_listener_before_close_and_removes_its_namespace
    with_runner(mode: 'accept-barrier') do |context|
      with_controller(context) do |pid, input, output|
        observe_runner(context, output, pid)
        input.write('.')
        input.flush
        status = Process.waitpid2(pid).last
        context[:controller_reaped] = true
        assert(status.success?)
        assert_retained_runner(context)
        shutdown(context)
        barrier = JSON.parse(File.read(File.join(context[:record]['state_dir'], 'listener-close.json')))
        assert_equal(2, barrier['accepts'])
        assert_equal(false, barrier['control_alive'])
        refute(File.exist?(context[:record]['socket_dir']))
        refute(File.exist?(File.join(context[:record]['socket_dir'], 'control.sock')))
      end
    end
  end

  def test_caller_expiry_retains_one_shutdown_and_tracks_late_children_until_reapers_complete
    delayed_shutdown
  end

  def test_signal_withdraws_ready_marker_and_repeated_control_only_waits_for_the_same_shutdown
    delayed_shutdown(signal_origin: true)
  end

  def delayed_shutdown(signal_origin: false)
    with_runner(mode: 'delayed-drain') do |context|
      server = UNIXServer.new(File.join(context[:state].root, 'drain.sock'))
      File.chmod(0o600, server.path)
      peer = waiter = nil
      with_controller(context) do |pid, input, output|
        observe_runner(context, output, pid)
        input.write('.'); input.flush
        assert(Process.waitpid2(pid).last.success?)
        context[:controller_reaped] = true
        context[:shutdown_attempted] = true
        context[:shutdown_attempts] = 1
        context[:engine].set_phase('ready', context[:record]['run_id'])
        assert(context[:engine].ready?(context[:record]))
        if signal_origin
          Process.kill('TERM', context[:runner]['pid'])
          peer = Timeout.timeout(5) { server.accept }
          assert_equal('ready', context[:engine].phase['phase'])
          assert(context[:engine].live?(context[:record]))
          refute(context[:engine].status['ready'])
          assert_raises(KbRuntime::Error) { context[:engine].connection }
        end
        failure = assert_raises(KbRuntime::Error) { context[:engine].stop(timeout: 0) }
        assert_match(/owned shutdown incomplete/, failure.message)
        peer ||= Timeout.timeout(5) { server.accept }
        stopped = JSON.parse(Timeout.timeout(5) { peer.gets })
        assert_equal('stop', stopped['stage'])
        assert_equal(1, stopped['timeout'], 'configured machine budget, not hard-coded 120')
        assert_equal('budget-expired', JSON.parse(Timeout.timeout(5) { peer.gets })['stage'])
        assert_equal('stopping', context[:engine].phase['phase'])
        refute(File.exist?(context[:state].path("ready-#{context[:record]['run_id']}.json")))
        assert_retained_runner(context)
        refute(context[:engine].process_record(context[:record])['complete'])
        assert_equal(context[:claims], Dir.glob(File.join(context[:engine].resources.root, '*.json')).to_h { |path| [path, File.binread(path)] })
        refute(File.exist?(File.join(context[:record]['state_dir'], 'cleaned')))

        # These exact authenticated requests and signals all target one drain.
        2.times do
          assert_raises(KbRuntime::Error) { context[:engine].stop(timeout: 0) }
          Process.kill('TERM', context[:runner]['pid'])
          Process.kill('INT', context[:runner]['pid'])
        end
        peer.puts('late')
        late = JSON.parse(Timeout.timeout(5) { peer.gets })
        assert_equal('late', late['stage'])
        proof = Timeout.timeout(5) do
          loop do
            current = context[:engine].process_record(context[:record])
            break current if current['children'].any? { |child| child['pid'] == late['pid'] }
            Thread.pass
          end
        end
        assert_equal(context[:runner], proof['runner'])
        assert_equal(2, proof['children'].size)
        refute(proof['complete'])
        peer.puts('exit')
        assert_equal({ 'stage' => 'reaped', 'running' => false }, JSON.parse(Timeout.timeout(5) { peer.gets }))
        refute(context[:engine].gone?(context[:record]), 'nil join and first child exit do not prove the late child gone')
        refute(context[:engine].process_record(context[:record])['complete'])
        assert_equal(1, File.readlines(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')).length)
        # Observe the real acknowledgement without competing for the stop lock.
        acknowledgement = Queue.new
        control = context[:engine].method(:control)
        context[:engine].define_singleton_method(:control) do |record, command|
          handoff = control.call(record, command)
          acknowledgement << [:acknowledged, nil]
          handoff
        end
        context[:engine].singleton_class.send(:private, :control)
        begin
          waiter = Thread.new do
            context[:engine].stop(timeout: 5)
            :stopped
          rescue StandardError, Minitest::Assertion => error
            acknowledgement << [:error, error]
            error
          end
          outcome, error = Timeout.timeout(5) { acknowledgement.pop }
          raise error if outcome == :error
          assert_equal(:acknowledged, outcome)
        ensure
          context[:engine].singleton_class.send(:remove_method, :control)
        end
        peer.puts('finish')
        assert_equal('finished', JSON.parse(Timeout.timeout(5) { peer.gets })['stage'])
        Timeout.timeout(5) { Thread.pass until context[:engine].gone?(context[:record]) }
        assert_equal(2, context[:engine].process_record(context[:record])['children'].size, 'identities are append-only')
        assert_equal(:stopped, Timeout.timeout(5) { waiter.value })
        assert_shutdown(context)
        assert_equal(1, File.readlines(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')).length)
        assert_equal(context[:runner], context[:engine].process_record(context[:record])['runner'])
      end
    ensure
      primary = $!
      cleanup_error = nil
      begin
        if File.exist?(context[:state].path("processes-#{context[:record]['run_id']}.json")) && !context[:engine].gone?(context[:record])
          unless context[:shutdown_attempted]
            context[:shutdown_attempted] = true
            context[:shutdown_attempts] = 1
            begin
              context[:engine].stop(timeout: 0)
            rescue KbRuntime::Error
              # First owned request only; release the fixture's child below.
            end
          end
          peer ||= Timeout.timeout(5) { server.accept }
          peer.puts('release') unless peer.closed?
          Timeout.timeout(5) { Thread.pass until context[:engine].gone?(context[:record]) }
        end
      rescue StandardError => error
        cleanup_error = error
        context[:drain_cleanup_error] = error
      ensure
        peer&.close unless peer&.closed?
        server&.close unless server&.closed?
        waiter&.join
      end
      raise cleanup_error if cleanup_error && !primary
    end
  end

  def test_queued_shutdown_at_the_ensure_boundary_does_not_replace_primary_failure
    with_runner(mode: 'primary-drain-error') do |context|
      out, error, status = Open3.capture3(*runner_argv(context))
      File.write(context[:log], out, mode: 'wb', perm: 0o600)
      File.write(context[:error], error, mode: 'wb', perm: 0o600)
      refute(status.success?)
      assert_match(/primary readiness fixture failure/, error)
      refute_match(/unhandled exception.*ShutdownRequested/, error)
      proof = context[:engine].process_record(context[:record])
      assert(proof['complete'])
      assert(context[:engine].gone?(context[:record]))
      refute(File.exist?(context[:state].path("ready-#{context[:record]['run_id']}.json")))
      assert_equal(1, File.readlines(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')).length)
      shutdown(context)
    end
  end

  def test_quiesced_task_disappearance_resumes_tracking_before_any_finalization_or_cleanup
    observation_shutdown('task-proof-before')
  end

  def test_quiesced_real_worker_child_is_retained_until_exit_before_finalization_or_cleanup
    observation_shutdown('task-proof-child')
  end

  def test_post_cleanup_task_disappearance_resumes_tracking_without_repeating_finalization
    observation_shutdown('task-proof-after')
  end

  def observation_shutdown(mode)
    with_runner(mode:) do |context|
      server = UNIXServer.new(File.join(context[:state].root, 'proof.sock'))
      File.chmod(0o600, server.path)
      peer = nil
      with_controller(context) do |pid, input, output|
        observe_runner(context, output, pid)
        input.write('.'); input.flush
        assert(Process.waitpid2(pid).last.success?)
        context[:controller_reaped] = true
        Timeout.timeout(5) do
          Thread.pass until File.exist?(File.join(context[:record]['state_dir'], 'tracker-started'))
        end
        context[:engine].set_phase('ready', context[:record]['run_id'])
        assert(context[:engine].ready?(context[:record]))
        context[:shutdown_attempted] = true
        context[:shutdown_attempts] = 1
        error = assert_raises(KbRuntime::Error) { context[:engine].stop(timeout: 0) }
        assert_match(/owned shutdown incomplete/, error.message)
        peer = Timeout.timeout(5) { server.accept }
        barrier = JSON.parse(Timeout.timeout(5) { peer.gets })
        assert_equal('tracker-resumed', barrier['stage'])
        assert_equal(mode == 'task-proof-after' ? 'post-cleanup' : 'quiesced', barrier['point'])
        assert(barrier['tracker_alive'])
        proof = context[:engine].process_record(context[:record])
        assert_equal(context[:runner], proof['runner'])
        refute(proof['complete'])
        assert(context[:engine].live?(context[:record]))
        refute(context[:engine].gone?(context[:record]))
        assert_equal('stopping', context[:engine].phase['phase'])
        refute(File.exist?(context[:state].path("ready-#{context[:record]['run_id']}.json")))
        assert_equal(context[:claims], Dir.glob(File.join(context[:engine].resources.root, '*.json')).to_h { |path| [path, File.binread(path)] })
        events_path = File.join(context[:record]['state_dir'], 'discovery-events.jsonl')
        events = File.readlines(events_path).map { |line| JSON.parse(line) }
        resumed = events.index { |event| event['stage'] == 'tracker-resumed' }
        observed = events.index { |event| event['stage'] == 'discovery' && event['point'] == barrier['point'] }
        joined = events.index { |event| event['stage'] == 'tracker-joined' }
        assert(joined && observed && resumed)
        assert_operator(joined, :<, observed)
        assert_operator(observed, :<, resumed)
        if mode == 'task-proof-after'
          assert(File.exist?(File.join(context[:record]['state_dir'], 'finalized')))
          assert(File.exist?(File.join(context[:record]['state_dir'], 'cleaned')))
          assert_operator(events.index { |event| event['stage'] == 'finalize' }, :<, observed)
          assert_operator(events.index { |event| event['stage'] == 'cleanup' }, :<, observed)
          assert(events[observed]['incomplete'])
        else
          refute(File.exist?(File.join(context[:record]['state_dir'], 'finalized')))
          refute(File.exist?(File.join(context[:record]['state_dir'], 'cleaned')))
          refute(events.any? { |event| %w[finalize cleanup].include?(event['stage']) })
          assert(events[observed]['incomplete']) if mode == 'task-proof-before'
        end
        if mode == 'task-proof-child'
          child = KbRuntime::ProcessIdentity.read(barrier['child'])
          assert(child)
          assert_includes(proof['children'], child)
          refute_includes(proof['children'].map { |record| record['pid'] }, barrier['worker_task'])
          assert_equal(2, proof['children'].length)
        end
        peer.puts('release')
        assert_equal('released', JSON.parse(Timeout.timeout(5) { peer.gets })['stage'])
        shutdown(context)
        terminal = context[:engine].process_record(context[:record])
        assert_equal(proof['children'], terminal['children'], 'retained identities cannot disappear between observations')
        events = File.readlines(events_path).map { |line| JSON.parse(line) }
        assert_equal(1, events.count { |event| event['stage'] == 'finalize' })
        assert_equal(1, events.count { |event| event['stage'] == 'cleanup' })
        assert_equal(1, File.readlines(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')).length)
        if mode != 'task-proof-after'
          assert_operator(resumed, :<, events.index { |event| event['stage'] == 'finalize' })
        end
        assert_operator(events.index { |event| event['stage'] == 'finalize' }, :<, events.index { |event| event['stage'] == 'cleanup' })
        assert(events.any? { |event| event['stage'] == 'discovery' && event['point'] == 'post-cleanup' && !event['incomplete'] })
        assert(KbRuntime::ProcessIdentity.gone?(child)) if child
      end
    ensure
      primary = $!
      begin
        if context[:shutdown_attempted] && !context[:engine].gone?(context[:record])
          peer ||= Timeout.timeout(5) { server.accept }
          peer.puts('release') unless peer.closed?
          Timeout.timeout(5) { Thread.pass until context[:engine].gone?(context[:record]) }
        end
      rescue StandardError => cleanup_error
        context[:drain_cleanup_error] = cleanup_error
        raise unless primary
      ensure
        peer&.close unless peer&.closed?
        server&.close unless server&.closed?
      end
    end
  end

  def test_primary_assertion_and_secondary_cleanup_failure_keep_original_error_and_private_evidence
    context = nil
    original = nil
    original_backtrace = nil
    _out, diagnostic = capture_io do
      raised = assert_raises(Minitest::Assertion) do
        with_runner do |fixture|
          context = fixture
          with_controller(fixture) do |pid, _input, output|
            observe_runner(fixture, output, pid)
            File.write(File.join(fixture[:record]['socket_dir'], 'unrelated'), 'untouched', mode: 'wb', perm: 0o600)
            begin
              flunk('primary fixture assertion token=private-example')
            rescue Minitest::Assertion => error
              original = error
              original_backtrace = error.backtrace.dup
              raise
            end
          end
        end
      end
      assert_same(original, raised)
      assert_equal(original_backtrace, raised.backtrace)
    end
    assert_equal(1, context[:shutdown_attempts])
    evidence = retained_evidence(context, diagnostic)
    assert_equal('Minitest::Assertion', evidence['primary']['class'])
    assert_match(/unrecognized retained socket contents/, evidence['secondary']['message'])
    assert_equal(original_backtrace, evidence['primary']['backtrace'])
    assert_equal(true, evidence['processes']['complete'])
    assert_equal(true, evidence['gone'])
    assert_equal('stopping', evidence['phase']['phase'])
    assert_equal([{ 'name' => 'unrelated', 'type' => 'file' }], evidence['socket_entries'])
    assert_equal(0, evidence['claims_count'])
    assert_match(/secondary cleanup/, diagnostic)
    refute_includes(diagnostic, 'private-example')
  end

  def test_primary_failure_survives_successful_public_cleanup
    context = nil
    original = nil
    _out, diagnostic = capture_io do
      raised = assert_raises(Minitest::Assertion) do
        with_runner do |fixture|
          context = fixture
          with_controller(fixture) do |pid, _input, output|
            observe_runner(fixture, output, pid)
            begin
              flunk('first fixture failure')
            rescue Minitest::Assertion => error
              original = error
              raise
            end
          end
        end
      end
      assert_same(original, raised)
    end
    evidence = retained_evidence(context, diagnostic)
    assert_nil(evidence['secondary'])
    assert_equal('stopped', evidence['phase']['phase'])
    assert_equal(true, evidence['processes']['complete'])
    assert_equal(true, evidence['gone'])
    assert_nil(evidence['socket_entries'])
    assert_equal(0, evidence['claims_count'])
    assert_equal(1, context[:shutdown_attempts])
  end

  def test_explicit_failed_stop_is_not_repeated_and_preserves_an_unrelated_socket_entry
    context = nil
    _out, diagnostic = capture_io do
      with_runner do |fixture|
        context = fixture
        with_controller(fixture) do |pid, input, output|
          observe_runner(fixture, output, pid)
          input.write('.')
          input.flush
          status = Process.waitpid2(pid).last
          fixture[:controller_reaped] = true
          assert(status.success?)
          leftover = File.join(fixture[:record]['socket_dir'], 'unrelated')
          File.write(leftover, 'untouched', mode: 'wb', perm: 0o600)
          inode = File.stat(leftover).ino
          error = assert_raises(KbRuntime::Error) { shutdown(fixture) }
          assert_match(/unrecognized retained socket contents/, error.message)
          assert_equal('untouched', File.read(leftover))
          assert_equal(inode, File.stat(leftover).ino)
          refute(File.exist?(File.join(fixture[:record]['socket_dir'], 'control.sock')))
          assert(fixture[:engine].gone?(fixture[:record]))
          assert(fixture[:engine].process_record(fixture[:record])['complete'])
          assert_empty(Dir.glob(File.join(fixture[:engine].resources.root, '*.json')))
          assert_equal('stopping', fixture[:engine].phase['phase'])
        end
      end
    end
    assert_equal(1, context[:shutdown_attempts])
    evidence = retained_evidence(context, diagnostic)
    assert_match(/unrecognized retained socket contents/, evidence['primary']['message'])
    assert_nil(evidence['secondary'])
    assert_equal([{ 'name' => 'unrelated', 'type' => 'file' }], evidence['socket_entries'])
  end

  def test_first_valid_stop_notifies_once_when_its_acknowledgement_hits_a_closed_client
    with_runner(mode: 'ack-loss') do |context|
      ack_server = UNIXServer.new(File.join(context[:state].root, 'ack.sock'))
      drain_server = UNIXServer.new(File.join(context[:state].root, 'ack-drain.sock'))
      [ack_server, drain_server].each { |server| File.chmod(0o600, server.path) }
      log = File.open(context[:log], File::WRONLY | File::CREAT | File::EXCL, 0o600)
      first = ack = drain = waiter = pid = owned_tuple = nil
      ack_released = false
      reap = lambda do
        Timeout.timeout(5) do
          loop do
            waited = Thread.handle_interrupt(Exception => :never) do
              result = Process.waitpid2(pid, Process::WNOHANG)
              pid = nil if result
              result
            end
            break waited.last if waited
            Thread.pass
          end
        end
      end
      context[:shutdown_attempted] = true
      begin
        # This test retains the sole waitpid owner. Even failure cleanup cannot
        # signal a reused PID: the directly spawned child has not been reaped.
        pid = Process.spawn(*runner_argv(context), in: File::NULL, out: log, err: log, close_others: true)
        owned_tuple = KbRuntime::ProcessIdentity.read(pid)
        assert(KbRuntime::ProcessIdentity.runner_matches?(owned_tuple, context[:record]))
        Timeout.timeout(5) do
          Thread.pass until File.exist?(context[:state].path("ready-#{context[:record]['run_id']}.json"))
        end
        proof = context[:engine].process_record(context[:record])
        assert_equal(owned_tuple, proof['runner'])
        assert_equal(pid, proof['runner']['pid'])
        context[:runner] = proof['runner']
        context[:children] = proof['children']
        assert_equal(1, proof['children'].length)
        context[:engine].set_phase('ready', context[:record]['run_id'])
        assert(context[:engine].ready?(context[:record]))
        request = { 'schema' => 1, 'instance_id' => context[:record]['instance_id'],
          'run_id' => context[:record]['run_id'], 'command' => 'stop' }
        control_path = File.join(context[:record]['socket_dir'], 'control.sock')
        invalid = UNIXSocket.new(control_path)
        invalid.puts(JSON.generate(request.merge('run_id' => SecureRandom.uuid)))
        assert_equal('', Timeout.timeout(5) { invalid.read }, 'an invalid request receives no acknowledgement')
        invalid.close
        assert(context[:engine].ready?(context[:record]), 'invalid requests cannot latch or notify')
        refute(File.exist?(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')))

        first = UNIXSocket.new(control_path)
        first.puts(JSON.generate(request))
        ack = Timeout.timeout(5) { ack_server.accept }
        assert_equal({ 'stage' => 'latched', 'ordinal' => 1 }, JSON.parse(Timeout.timeout(5) { ack.gets }))
        refute(context[:engine].ready?(context[:record]))
        refute(File.exist?(context[:state].path("ready-#{context[:record]['run_id']}.json")))
        refute(File.exist?(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')), 'the actual first reply is still blocked')
        first.shutdown(Socket::SHUT_RDWR)
        first.close
        ack.puts('reply')
        ack_released = true
        failure = JSON.parse(Timeout.timeout(5) { ack.gets })
        assert_equal('reply-failed', failure['stage'])
        assert_equal(1, failure['ordinal'])
        assert_equal('Errno::EPIPE', failure['class'], 'the underlying real socket write must fail')
        assert_includes(%w[puts flush], failure['operation'])
        assert_equal(failure, JSON.parse(File.read(File.join(context[:record]['state_dir'], 'ack-native.json'))))
        drain = Timeout.timeout(5) { drain_server.accept }
        stopped = JSON.parse(Timeout.timeout(5) { drain.gets })
        assert_equal('stop', stopped['stage'])
        assert_equal(proof['children'].first['pid'], stopped['child'])
        assert_equal(5, stopped['timeout'])
        assert_retained_runner(context)
        refute(context[:engine].process_record(context[:record])['complete'])
        assert_equal(context[:claims], Dir.glob(File.join(context[:engine].resources.root, '*.json')).to_h { |path| [path, File.binread(path)] })
        refute(File.exist?(File.join(context[:record]['state_dir'], 'finalized')))
        refute(File.exist?(File.join(context[:record]['state_dir'], 'cleaned')))

        waiter = Thread.new do
          context[:engine].stop(timeout: 5)
          :stopped
        rescue StandardError => error
          error
        end
        later_reply = File.join(context[:record]['state_dir'], 'ack-success-2.json')
        Timeout.timeout(5) { Thread.pass until File.exist?(later_reply) }
        assert_equal({ 'stage' => 'reply-delivered', 'ordinal' => 2 }, JSON.parse(File.read(later_reply)))
        assert(waiter.alive?, 'the later public stop waits for the existing live child')
        assert_equal('stopping', context[:engine].phase['phase'])
        assert_retained_runner(context)
        refute(context[:engine].process_record(context[:record])['complete'])
        assert_equal(context[:claims], Dir.glob(File.join(context[:engine].resources.root, '*.json')).to_h { |path| [path, File.binread(path)] })
        assert_equal(1, File.readlines(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')).length)
        drain.puts('release')
        assert_equal(:stopped, Timeout.timeout(5) { waiter.value })
        assert_shutdown(context)
        assert_equal(1, File.readlines(File.join(context[:record]['state_dir'], 'stop-calls.jsonl')).length)
        assert_equal(proof['children'], context[:engine].process_record(context[:record])['children'])
        status = reap.call
        assert(status.success?, 'the same directly owned runner exits normally')
      ensure
        primary = $!
        cleanup_error = nil
        begin
          first&.close unless first&.closed?
          if primary && ack && !ack.closed? && !ack_released
            begin
              ack.puts('reply')
            rescue IOError, SystemCallError => error
              cleanup_error = error
              context[:drain_cleanup_error] = error
            end
          end
          if pid && primary && !drain && KbRuntime::ProcessIdentity.matches?(owned_tuple)
            unless owned_tuple['pid'] == pid && KbRuntime::ProcessIdentity.runner_matches?(owned_tuple, context[:record])
              raise KbRuntime::Error, 'synthetic unreaped runner identity differs during failure cleanup'
            end
            Process.kill('TERM', pid)
          end
          if pid && owned_tuple && !KbRuntime::ProcessIdentity.gone?(owned_tuple)
            drain ||= Timeout.timeout(5) { drain_server.accept }
            drain.puts('release') unless drain.closed?
          end
          reap.call if pid
        rescue StandardError => error
          cleanup_error ||= error
          context[:drain_cleanup_error] ||= error
        ensure
          [invalid, first, ack, drain, ack_server, drain_server, log].compact.each { |stream| stream.close unless stream.closed? }
          waiter&.join(5)
        end
        raise cleanup_error if cleanup_error && !primary
      end
    end
  end

  private

  def with_runner(mode: 'normal')
    Dir.mktmpdir('kb-session-', '/tmp') do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'session-test')
      identity = state.transaction(create: true) { state.initialize_identity }
      resources = KbRuntime::Resources.new(state, root: File.join(directory, 'claims'))
      record = identity.merge('run_id' => SecureRandom.uuid, 'artifact_id' => SecureRandom.uuid,
        'boot_id' => KbRuntime::ProcessIdentity.boot_id, 'network_id' => 'synthetic-network', 'resource_claims' => [])
      record['state_dir'] = state.path('disks')
      record['socket_dir'] = resources.socket_dir(record['instance_id'], record['run_id'])
      state.private_directory(record['state_dir'], create: true)
      state.private_directory(record['socket_dir'], create: true)
      config = state.path('config.json')
      state.write(config, { 'machines' => {} })
      record['config_path'] = config
      artifact = state.path("artifact-#{record['artifact_id']}.json")
      state.write(artifact, { 'schema' => 1, 'instance_id' => record['instance_id'], 'artifact_id' => record['artifact_id'] })
      record['artifact_sha256'] = Digest::SHA256.file(artifact).hexdigest
      entrypoint = File.join(directory, 'runner-fixture.rb')
      load_paths = File.join(directory, 'load-paths.json')
      File.write(load_paths, JSON.generate($LOAD_PATH), mode: 'wb', perm: 0o600)
      File.write(entrypoint, runner_program, mode: 'wb', perm: 0o600)
      record['runner_identity'] = { 'executable' => RbConfig.ruby, 'entrypoint' => entrypoint }
      record['runner'] = entrypoint
      state.write(state.path("launch-#{record['run_id']}.json"), record, immutable: true)
      state.write(state.path("spawn-#{record['run_id']}.json"), { 'stage' => 'spawned' })
      state.write(state.path('phase.json'), { 'phase' => 'starting', 'run_id' => record['run_id'] })
      resources.claim(record)
      context = { state:, record:, entrypoint:, load_paths:, mode:,
        marker: File.join(record['state_dir'], 'machine.json'),
        generation: File.join(directory, 'generation.lock'),
        log: File.join(directory, 'runner.log'), error: File.join(directory, 'controller-error.log'),
        engine: KbRuntime::Engine.new(state:, software: nil, controller: [], resources:) }
      context[:claims] = Dir.glob(File.join(resources.root, '*.json')).to_h { |path| [path, File.binread(path)] }
      primary = nil
      secondary = nil
      begin
        yield context
      rescue StandardError, Minitest::Assertion => error
        primary = error
      ensure
        if !context[:shutdown_attempted] && File.exist?(state.path("processes-#{record['run_id']}.json"))
          begin
            context[:shutdown_attempted] = true
            context[:shutdown_attempts] = 1
            context[:engine].stop(timeout: 5) unless context[:engine].phase['phase'] == 'stopped'
          rescue StandardError, Minitest::Assertion => error
            secondary = error
          end
        end
        secondary ||= context[:drain_cleanup_error]
        failure = primary || context[:shutdown_error] || secondary
        if failure
          cleanup_error = primary ? secondary : nil
          retain_failure(context, failure, cleanup_error)
        end
      end
      raise primary if primary
      raise secondary if secondary
    end
  end

  def retain_failure(context, primary, secondary)
    directory = Dir.mktmpdir('kb-runner-evidence-', '/tmp')
    logs = %i[log error].filter_map do |key|
      source = context.fetch(key)
      next unless File.file?(source)
      target = File.join(directory, File.basename(source))
      FileUtils.copy_file(source, target)
      File.chmod(0o600, target)
      { 'name' => File.basename(target), 'sha256' => Digest::SHA256.file(target).hexdigest, 'bytes' => File.size(target) }
    end
    sockets = context[:record].fetch('socket_dir')
    entries = if File.directory?(sockets)
                Dir.children(sockets).sort.first(32).map do |name|
                  info = File.lstat(File.join(sockets, name))
                  { 'name' => name, 'type' => info.ftype }
                end
              end
    process_path = context[:state].path("processes-#{context[:record]['run_id']}.json")
    processes = context[:state].read(process_path) if File.exist?(process_path)
    listener_path = File.join(context[:record]['state_dir'], 'listener-close.json')
    details = { 'primary' => exception_details(primary), 'secondary' => exception_details(secondary), 'logs' => logs,
      'phase' => context[:engine].phase, 'processes' => processes&.slice('complete', 'run_id', 'artifact_id'),
      'gone' => processes && context[:engine].gone?(context[:record]),
      'listener_close' => File.file?(listener_path) ? JSON.parse(File.read(listener_path)) : nil,
      'socket_entries' => entries, 'socket_entries_truncated' => File.directory?(sockets) && Dir.children(sockets).length > 32,
      'claims_count' => Dir.glob(File.join(context[:engine].resources.root, '*.json')).length }
    path = File.join(directory, 'failure.json')
    File.write(path, JSON.pretty_generate(details), mode: 'wb', perm: 0o600)
    context[:evidence] = path
    hash = Digest::SHA256.file(path).hexdigest
    warn "Runner fixture failed: #{failure_excerpt(primary)}; evidence=#{path} sha256=#{hash}"
    warn "Runner fixture secondary cleanup: #{failure_excerpt(secondary)}" if secondary
    logs.each do |log|
      source = File.join(directory, log['name'])
      lines = File.readlines(source).grep(/\b(?:[\w:]*Error|failed|refusal)\b/).last(2)
      next if lines.empty?
      excerpt = redact_failure(lines.join(' ').gsub(/[\r\n]/, ' ')).byteslice(0, 768)
      warn "Runner fixture native #{log['name']}: #{excerpt}; sha256=#{log['sha256']}"
    end
  rescue StandardError => error
    warn "Runner fixture diagnostic retention failed: #{failure_excerpt(error)}"
  end

  def exception_details(error)
    error && { 'class' => error.class.name, 'message' => error.message, 'backtrace' => error.backtrace }
  end

  def failure_excerpt(error)
    value = "#{error.class}: #{error.message.to_s.lines.first.to_s.strip} #{Array(error.backtrace).first(3).join(' ')}"
    redact_failure(value).byteslice(0, 768)
  end

  def redact_failure(value)
    value.gsub(/((?:token|password|secret|credential)\s*[=:]\s*)\S+/i, '\\1[redacted]')
  end

  def retained_evidence(context, diagnostic)
    path = context.fetch(:evidence)
    assert(File.file?(path))
    assert_equal(0o700, File.stat(File.dirname(path)).mode & 0o777)
    assert_equal(0o600, File.stat(path).mode & 0o777)
    assert_includes(diagnostic, path)
    assert_includes(diagnostic, Digest::SHA256.file(path).hexdigest)
    refute(File.exist?(context[:log]), 'deleted fixture log must not be cited as retained evidence')
    details = JSON.parse(File.read(path))
    details['logs'].each do |log|
      retained = File.join(File.dirname(path), log['name'])
      assert_equal(0o600, File.stat(retained).mode & 0o777)
      assert_equal(log['sha256'], Digest::SHA256.file(retained).hexdigest)
    end
    details
  end

  def runner_argv(context)
    record = context[:record]
    [RbConfig.ruby, context[:entrypoint], context[:load_paths], context[:mode], 'start',
      '--config', record['config_path'], '--state-dir', record['state_dir'], '--sock-dir', record['socket_dir'],
      '--launch-file', context[:state].path("launch-#{record['run_id']}.json"), '--state-root', context[:state].root,
      '--slug', context[:state].slug, '--instance-id', record['instance_id'], '--run-id', record['run_id'],
      '--artifact-id', record['artifact_id'], '--artifact-sha256', record['artifact_sha256'], '--timeout', context[:mode] == 'delayed-drain' ? '1' : '5']
  end

  def with_controller(context)
    input, input_writer = IO.pipe
    output_reader, output = IO.pipe
    program = <<~RUBY
      require 'json'
      require 'timeout'
      require #{File.expand_path('../cluster/lib/kb_state', __dir__).inspect}
      state = KbRuntime::State.new(ARGV.shift, ARGV.shift)
      generation_path = ARGV.shift
      ready = ARGV.shift
      log = File.open(ARGV.shift, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      STDOUT.sync = true
      state.lock('gate', wait: false) do |gate|
        state.lock('operation', wait: false) do |operation|
          File.open(generation_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |generation|
            generation.flock(File::LOCK_EX)
            [gate, operation, generation].each { |stream| stream.close_on_exec = false }
            pid = Process.spawn(*ARGV, in: File::NULL, out: log, err: log, close_others: true)
            Timeout.timeout(5) { sleep 0.01 until File.exist?(ready) }
            puts JSON.generate('controller_pid' => Process.pid, 'runner_pid' => pid, 'session' => Process.getsid(0), 'group' => Process.getpgrp)
            STDIN.read(1)
          end
        end
      end
    RUBY
    error = File.open(context[:error], File::WRONLY | File::CREAT | File::EXCL, 0o600)
    pid = Process.spawn(RbConfig.ruby, '-e', program, context[:state].root, context[:state].slug,
      context[:generation], context[:state].path("ready-#{context[:record]['run_id']}.json"), context[:log],
      *runner_argv(context), in: input, out: output, err: error, pgroup: true, close_others: true)
    error.close
    input.close
    output.close
    yield pid, input_writer, output_reader
  ensure
    input_writer&.close unless input_writer&.closed?
    Process.waitpid(pid) if pid && !context[:controller_reaped]
    [input, input_writer, output_reader, output, error].compact.each { |stream| stream.close unless stream.closed? }
  end

  def observe_runner(context, output, controller_pid)
    text = Timeout.timeout(5) { output.gets }
    refute_nil(text, 'controller did not start; native diagnostics will be retained privately')
    controller = JSON.parse(text)
    assert_equal(controller_pid, controller['controller_pid'])
    assert_equal(controller_pid, controller['group'])
    proof = context[:engine].process_record(context[:record])
    assert_equal(controller['runner_pid'], proof['runner']['pid'])
    assert_equal(context[:record]['boot_id'], proof['runner']['boot_id'])
    assert_equal(Process.uid, proof['runner']['owner_uid'])
    assert(KbRuntime::ProcessIdentity.runner_matches?(proof['runner'], context[:record]))
    context[:runner] = proof['runner']
    context[:children] = proof['children']
    marker = JSON.parse(File.read(context[:marker]))
    assert_equal(proof['runner']['pid'], marker['session'])
    assert_equal(proof['runner']['pid'], marker['group'])
    refute_equal(controller['session'], marker['session'])
    guard_paths = %w[gate operation].map { |kind| File.join(context[:state].root, 'locks', "#{context[:state].slug}.#{kind}.lock") }
    (guard_paths + [context[:generation]]).each { |path| refute_includes(marker['fds'], path) }
    assert_equal(1, proof['children'].length)
    assert_equal(marker['session'], Process.getsid(proof['children'].first['pid']))
  end

  def assert_retained_runner(context)
    assert_equal(context[:runner], KbRuntime::ProcessIdentity.read(context[:runner]['pid']))
    assert_equal(context[:children], context[:engine].process_record(context[:record])['children'])
    assert(context[:children].all? { |child| KbRuntime::ProcessIdentity.matches?(child) })
    assert_equal(context[:runner]['pid'], Process.getsid(context[:runner]['pid']))
    assert_equal(context[:runner]['pid'], Process.getpgid(context[:runner]['pid']))
  end

  def shutdown(context)
    context[:shutdown_attempted] = true
    context[:shutdown_attempts] = context.fetch(:shutdown_attempts, 0) + 1
    begin
      context[:engine].stop(timeout: 5)
    rescue StandardError, Minitest::Assertion => error
      context[:shutdown_error] = error
      raise
    end
    assert_shutdown(context)
  end

  def assert_shutdown(context)
    assert_equal('stopped', context[:engine].phase['phase'])
    assert(context[:engine].process_record(context[:record])['complete'])
    assert(context[:engine].gone?(context[:record]))
    assert_empty(Dir.glob(File.join(context[:engine].resources.root, '*.json')))
    assert(File.exist?(File.join(context[:record]['state_dir'], 'finalized')))
    assert(File.exist?(File.join(context[:record]['state_dir'], 'cleaned')))
    refute(File.exist?(context[:record]['socket_dir']))
  end

  def runner_program
    <<~RUBY
      require 'json'
      require 'rbconfig'
      $LOAD_PATH.replace(JSON.parse(File.read(ARGV.shift)))
      require #{File.expand_path('../cluster/lib/devcluster_runner', __dir__).inspect}
      mode = ARGV.shift
      $session_fixture_mode = mode
      if mode == 'primary-drain-error'
        original_read = KbRuntime::State.instance_method(:read)
        KbRuntime::State.define_method(:read) do |path, **options|
          begin
            original_read.bind_call(self, path, **options)
          ensure
            if File.basename(path).start_with?('ready-') && !@queued_shutdown_fixture
              @queued_shutdown_fixture = true
              Thread.new { Thread.main.raise DevClusters::OsVmRunner::ShutdownRequested }.join
            end
          end
        end
      end
      if mode == 'own-session'
        Process.setsid
        Process.define_singleton_method(:setsid) { raise 'setsid called twice' }
      elsif mode == 'session-failure'
        Process.define_singleton_method(:setsid) { raise Errno::EPERM, 'injected setsid refusal' }
      end
      if mode == 'accept-barrier'
        class ListenerBarrier
          def initialize(server, directory)
            @server = server
            @directory = directory
            @accepts = 0
            @entered = Queue.new
          end
          def accept
            @accepts += 1
            if @accepts == 2
              @control_thread = Thread.current
              @entered << true
            end
            @server.accept
          end
          def wait_for_next_accept
            Timeout.timeout(5) { @entered.pop }
          end
          def close
            alive = @control_thread.alive?
            File.write(File.join(@directory, 'listener-close.json'), JSON.generate('accepts' => @accepts,
              'control_alive' => alive), mode: 'wb', perm: 0o600)
            @server.close
            @control_thread.join if alive
          end
        end
        directory = ARGV[ARGV.index('--state-dir') + 1]
        original_server = UNIXServer.method(:new)
        UNIXServer.define_singleton_method(:new) do |path|
          $shutdown_listener = ListenerBarrier.new(original_server.call(path), directory)
        end
      end
      class SessionMachine
        def initialize(directory)
          @directory = directory
        end
        def start(wait_for_boot:)
          reader, @writer = IO.pipe
          @child = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: reader, close_others: true)
          reader.close
          @running = true
          @reaper = Thread.new do
            Process.wait(@child)
            @running = false
          end
        end
        def running?
          @running
        end
        def join(timeout:)
          @reaper.join(timeout)
          nil # The pinned public API discards its timeout result.
        end
        def wait_for_boot(timeout:)
          fds = Dir.children('/proc/self/fd').filter_map do |name|
            File.readlink('/proc/self/fd/' + name) rescue nil
          end
          File.write(File.join(@directory, 'machine.json'), JSON.generate('session' => Process.getsid(0),
            'group' => Process.getpgrp, 'fds' => fds), mode: 'wb', perm: 0o600)
          raise 'primary readiness fixture failure' if $session_fixture_mode == 'primary-drain-error'
        end
        def stop(timeout:)
          $shutdown_listener.wait_for_next_accept if $shutdown_listener
          File.open(File.join(@directory, 'stop-calls.jsonl'), 'a', 0o600) { |file| file.puts(JSON.generate('timeout' => timeout)) }
          if $session_fixture_mode == 'delayed-drain'
            @drain = UNIXSocket.new(File.join(File.dirname(File.dirname(File.dirname(@directory))), 'drain.sock'))
            @drain.puts(JSON.generate('stage' => 'stop', 'child' => @child, 'timeout' => timeout))
            @commands = Thread.new do
              while (command = @drain.gets)
                case command.strip
                when 'late'
                  reader, @late_writer = IO.pipe
                  @late_child = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: reader, close_others: true)
                  reader.close
                  @drain.puts(JSON.generate('stage' => 'late', 'pid' => @late_child))
                when 'exit'
                  @writer.close
                  @reaper.join
                  @drain.puts(JSON.generate('stage' => 'reaped', 'running' => running?))
                when 'release'
                  @writer.close unless @writer.closed?
                  @reaper.join
                  @late_writer&.close unless @late_writer&.closed?
                  Process.wait(@late_child) if @late_child
                  break
                when 'finish'
                  @late_writer.close
                  Process.wait(@late_child)
                  @drain.puts(JSON.generate('stage' => 'finished'))
                  break
                else
                  raise 'unexpected owned drain barrier command'
                end
              end
            end
            unless @reaper.join(timeout)
              @drain.puts(JSON.generate('stage' => 'budget-expired'))
              raise 'injected machine operation budget expired'
            end
          else
            @writer.close
            @reaper.join
          end
        end
        def finalize
          @commands&.join
          @drain&.close
          File.write(File.join(@directory, 'finalized'), '', mode: 'wb', perm: 0o600)
        end
        def cleanup
          File.write(File.join(@directory, 'cleaned'), '', mode: 'wb', perm: 0o600)
        end
      end
      class SessionRunner < DevClusters::OsVmRunner
        def build_machines(opts)
          [MachineState.new(name: 'services', machine: SessionMachine.new(opts[:state_dir]))]
        end
      end
      if mode.start_with?('task-proof-')
        class TaskProofMachine < SessionMachine
          def stop(timeout:)
            @proof_peer = UNIXSocket.new(File.join(File.dirname(File.dirname(File.dirname(@directory))), 'proof.sock'))
            super
            @stopped = true
            event('stopped')
          end
          def event(stage, values = {})
            File.open(File.join(@directory, 'discovery-events.jsonl'), 'a', 0o600) do |file|
              file.puts(JSON.generate(values.merge('stage' => stage)))
            end
          end
          def before_discovery
            if Thread.current != Thread.main
              unless @tracker.equal?(Thread.current)
                @tracker = Thread.current
                @quiesced = false
                join = @tracker.method(:join)
                machine = self
                @tracker.define_singleton_method(:join) do |*args|
                  result = join.call(*args)
                  machine.tracker_joined if result && !alive?
                  result
                end
                event('tracker-started')
                File.write(File.join(@directory, 'tracker-started'), '', mode: 'wb', perm: 0o600)
              end
              return unless @stopped && !running?
              if @resume_pending
                value = { 'point' => @injected_point, 'tracker_alive' => Thread.current.alive?,
                  'child' => @proof_child, 'worker_task' => @proof_worker_task }
                event('tracker-resumed', value)
                @proof_peer.puts(JSON.generate(value.merge('stage' => 'tracker-resumed')))
                command = Timeout.timeout(5) { @proof_peer.gets }
                raise 'unexpected proof barrier command' unless command.nil? || command.strip == 'release'
                if @proof_child
                  @proof_writer.close
                  Process.wait(@proof_child)
                  @proof_child = nil
                end
                @resume_pending = false
                @proof_peer.puts(JSON.generate('stage' => 'released')) if command
              end
              return
            end
            return unless @stopped && !running?
            point = @cleaned ? 'post-cleanup' : (@quiesced ? 'quiesced' : 'initial')
            inject = !@injected && point == ($session_fixture_mode == 'task-proof-after' ? 'post-cleanup' : 'quiesced')
            if inject && $session_fixture_mode == 'task-proof-child'
              Thread.new do
                reader, @proof_writer = IO.pipe
                @proof_child = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: reader, close_others: true)
                @proof_worker_task = Thread.current.native_thread_id
                reader.close
              end.value
              Timeout.timeout(5) { Thread.pass while File.directory?('/proc/' + Process.pid.to_s + '/task/' + @proof_worker_task.to_s) }
            end
            { point:, inject: }
          end
          def after_discovery(pass, observation)
            return unless pass
            if pass[:inject]
              @injected = true
              @injected_point = pass[:point]
              observation[:incomplete] = true unless $session_fixture_mode == 'task-proof-child'
              @resume_pending = true
            elsif @resume_pending
              # The resumed tracker, rather than a racing main-thread pass,
              # owns the barrier that the test will release.
              observation[:incomplete] = true
            end
            event('discovery', { 'point' => pass[:point], 'incomplete' => !!observation[:incomplete],
              'children' => observation[:records].map { |record| record['pid'] } })
          end
          def tracker_joined
            @quiesced = true
            event('tracker-joined')
          end
          def finalize
            event('finalize')
            super
          end
          def cleanup
            event('cleanup')
            super
            @cleaned = true
          end
          def close_proof
            @proof_writer&.close unless @proof_writer&.closed?
            Timeout.timeout(5) { Process.wait(@proof_child) } if @proof_child
            @proof_peer&.close
          end
        end
        class SessionRunner
          def build_machines(opts)
            $task_proof = TaskProofMachine.new(opts[:state_dir])
            [MachineState.new(name: 'services', machine: $task_proof)]
          end
        end
        original_descendants = KbRuntime::ProcessIdentity.method(:descendants)
        KbRuntime::ProcessIdentity.define_singleton_method(:descendants) do |pid, observation: {}|
          pass = $task_proof&.before_discovery
          records = original_descendants.call(pid, observation:)
          $task_proof&.after_discovery(pass, observation)
          records
        end
        at_exit { $task_proof&.close_proof }
      end
      if mode == 'ack-loss'
        directory = ARGV[ARGV.index('--state-dir') + 1]
        root = File.dirname(File.dirname(File.dirname(directory)))
        write_reply = lambda do |name, value|
          path = File.join(directory, name)
          File.write(path + '.tmp', JSON.generate(value), mode: 'wb', perm: 0o600)
          File.rename(path + '.tmp', path)
        end
        original_server = UNIXServer.method(:new)
        ordinal = 0
        UNIXServer.define_singleton_method(:new) do |path|
          server = original_server.call(path)
          accept = server.method(:accept)
          server.define_singleton_method(:accept) do
            peer = accept.call
            native_puts, native_flush, native_close = peer.method(:puts), peer.method(:flush), peer.method(:close)
            reply = observer = nil
            failed = lambda do |error, operation|
              value = { 'stage' => 'reply-failed', 'ordinal' => reply, 'class' => error.class.name,
                'operation' => operation }
              write_reply.call('ack-native.json', value)
              warn 'Ack reply failed: ' + JSON.generate(value)
              observer.puts(JSON.generate(value)) if observer
            end
            peer.define_singleton_method(:puts) do |*values|
              unless reply
                ordinal += 1
                reply = ordinal
                if reply == 1
                  observer = UNIXSocket.new(File.join(root, 'ack.sock'))
                  observer.puts(JSON.generate('stage' => 'latched', 'ordinal' => reply))
                  command = Timeout.timeout(5) { observer.gets }
                  raise 'unexpected reply barrier command' unless command && command.strip == 'reply'
                end
              end
              begin
                native_puts.call(*values)
              rescue IOError, SystemCallError => error
                failed.call(error, 'puts')
                raise
              end
            end
            peer.define_singleton_method(:flush) do
              begin
                result = native_flush.call
              rescue IOError, SystemCallError => error
                failed.call(error, 'flush')
                raise
              else
                write_reply.call('ack-success-' + reply.to_s + '.json', { 'stage' => 'reply-delivered', 'ordinal' => reply })
                result
              end
            end
            peer.define_singleton_method(:close) do
              begin
                observer&.close unless observer&.closed?
              ensure
                native_close.call
              end
            end
            peer
          end
          server
        end
        class AckLossMachine < SessionMachine
          def stop(timeout:)
            File.open(File.join(@directory, 'stop-calls.jsonl'), 'a', 0o600) { |file| file.puts(JSON.generate('timeout' => timeout)) }
            @drain = UNIXSocket.new(File.join(File.dirname(File.dirname(File.dirname(@directory))), 'ack-drain.sock'))
            @drain.puts(JSON.generate('stage' => 'stop', 'child' => @child, 'timeout' => timeout))
            @commands = Thread.new do
              command = @drain.gets
              raise 'unexpected acknowledgement drain command' unless command.nil? || command.strip == 'release'
            ensure
              @writer.close unless @writer.closed?
              @reaper.join
            end
          end
        end
        class SessionRunner
          def build_machines(opts)
            [MachineState.new(name: 'services', machine: AckLossMachine.new(opts[:state_dir]))]
          end
        end
      end
      exit SessionRunner.run(ARGV, hash_base: 'synthetic-network')
    RUBY
  end
end
