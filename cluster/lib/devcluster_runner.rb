# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'osvm'
require 'time'
require 'socket'
require 'timeout'
require_relative 'kb_state'
require_relative 'kb_process'
require_relative 'kb_machine'

module DevClusters
  class OsVmRunner
    ShutdownRequested = Class.new(StandardError)
    MachineState = Struct.new(:name, :machine, keyword_init: true)

    def self.run(argv, hash_base:, priority_machines: [])
      new(argv, hash_base:, priority_machines:).run
    end

    def initialize(argv, hash_base:, priority_machines:)
      @argv = argv
      @hash_base = hash_base
      @priority_machines = priority_machines
    end

    def run
      establish_session
      command = @argv.shift

      case command
      when 'start'
        start
      else
        warn "Usage: #{$PROGRAM_NAME} start --config PATH --state-dir DIR --sock-dir DIR --launch-file PATH --state-root DIR --slug SLUG --instance-id ID --run-id ID"
        2
      end
    end

    private

    attr_reader :hash_base, :priority_machines

    def establish_session
      Process.setsid unless Process.getsid(0) == Process.pid
    end

    def start
      opts = {
        timeout: 900
      }

      OptionParser.new do |parser|
        parser.on('--config PATH') { |v| opts[:config] = v }
        parser.on('--state-dir DIR') { |v| opts[:state_dir] = v }
        parser.on('--sock-dir DIR') { |v| opts[:sock_dir] = v }
        parser.on('--launch-file PATH') { |v| opts[:launch_file] = v }
        parser.on('--state-root PATH') { |v| opts[:state_root] = v }
        parser.on('--slug SLUG') { |v| opts[:slug] = v }
        parser.on('--instance-id ID') { |v| opts[:instance_id] = v }
        parser.on('--run-id ID') { |v| opts[:run_id] = v }
        parser.on('--artifact-id ID') { |v| opts[:artifact_id] = v }
        parser.on('--artifact-sha256 SHA') { |v| opts[:artifact_sha256] = v }
        parser.on('--timeout SECONDS', Integer) { |v| opts[:timeout] = v }
      end.parse!(@argv)

      %i[config state_dir sock_dir launch_file state_root slug instance_id run_id artifact_id artifact_sha256].each do |key|
        raise ArgumentError, "--#{key.to_s.tr('_', '-')} is required" unless opts[key]
      end

      state = KbRuntime::State.new(opts[:state_root], opts[:slug])
      launch = state.read(opts[:launch_file])
      unless state.identity['instance_id'] == opts[:instance_id] && launch['instance_id'] == opts[:instance_id] && launch['run_id'] == opts[:run_id] &&
             launch['config_path'] == opts[:config] && launch['state_dir'] == opts[:state_dir] && launch['socket_dir'] == opts[:sock_dir] &&
             launch['artifact_id'] == opts[:artifact_id] && launch['artifact_sha256'] == opts[:artifact_sha256] &&
             launch['boot_id'] == KbRuntime::ProcessIdentity.boot_id
        raise KbRuntime::Error, 'runner launch identity differs'
      end
      state.private_directory(opts[:state_dir]) || raise(KbRuntime::Error, 'runner state is absent')
      state.private_directory(opts[:sock_dir]) || raise(KbRuntime::Error, 'runner sockets are absent')
      @hash_base = launch.fetch('network_id')
      artifact_bytes = state.file(state.path("artifact-#{launch.fetch('artifact_id')}.json"))
      raise KbRuntime::Error, 'runner artifact differs' unless Digest::SHA256.hexdigest(artifact_bytes) == launch['artifact_sha256']
      @artifact = JSON.parse(artifact_bytes)
      @state = state

      state.lock('runner', create: true) { run_owned(opts, state, launch) }
    end

    def run_owned(opts, state, launch)
      File.umask(0o077)
      process_path = state.path("processes-#{opts[:run_id]}.json")
      ready_path = state.path("ready-#{opts[:run_id]}.json")
      runner = KbRuntime::ProcessIdentity.read(Process.pid)
      raise KbRuntime::Error, 'runner tuple differs' unless KbRuntime::ProcessIdentity.runner_matches?(runner, launch)
      children = {}
      mutex = Mutex.new
      stopping = false
      shutdown_error = nil
      tracking = true
      @started_machines = []
      discover = proc do
        observation = { incomplete: false }
        begin
          KbRuntime::ProcessIdentity.descendants(Process.pid, observation:)
        ensure
          Array(observation[:records]).each { |record| children[[record['pid'], record['start_ticks']]] = record }
        end
        !observation[:incomplete]
      end
      write_processes = proc do |complete|
        state.write(process_path, { 'schema' => 1, 'instance_id' => opts[:instance_id], 'run_id' => opts[:run_id],
          'artifact_id' => opts[:artifact_id], 'artifact_sha256' => opts[:artifact_sha256],
          'runner' => runner, 'children' => children.values, 'complete' => complete })
      end
      publish = proc { mutex.synchronize { discover.call; write_processes.call(false) } }
      withdraw_ready = proc do
        begin
          marker = state.read(ready_path)
          unless marker['schema'] == 1 && %w[instance_id run_id artifact_id artifact_sha256].all? { |key| marker[key] == launch[key] }
            raise KbRuntime::Error, 'foreign readiness receipt during shutdown'
          end
          File.unlink(ready_path)
        rescue Errno::ENOENT
          # Shutdown may begin before the startup marker was published.
        end
      end
      latch_shutdown = proc do
        mutex.synchronize do
          next false if stopping
          stopping = true
          begin
            withdraw_ready.call
          rescue KbRuntime::Error, SystemCallError => error
            # Unsafe readiness is never unlinked, but cannot abandon live
            # machines/reapers. Preserve the failure after owned drain.
            shutdown_error ||= error
            warn "Readiness withdrawal failed: #{error.class}: #{error.message}"
          end
          true
        end
      end
      publish.call
      machines = build_machines(opts)

      # Only this one-shot notifier raises into the normal body. The trap itself
      # uses no mutex, and repeated requests remain acknowledgement-only.
      Thread.handle_interrupt(ShutdownRequested => :never) do
        signal_reader, signal_writer = IO.pipe
        signal_thread = Thread.new do
          if signal_reader.read(1)
            latch_shutdown.call
            Thread.main.raise ShutdownRequested
          end
        end
        signal_trap = proc do
          begin
            signal_writer.write_nonblock('.')
          rescue IO::WaitWritable, IOError, Errno::EPIPE
            # The one-shot notifier is already notified or quiesced.
          end
        end
        Signal.trap('TERM', &signal_trap)
        Signal.trap('INT', &signal_trap)

        control_path = File.join(opts[:sock_dir], 'control.sock')
        raise KbRuntime::Error, 'control socket already exists' if File.exist?(control_path) || File.symlink?(control_path)
        server = UNIXServer.new(control_path)
        File.chmod(0o600, control_path)
        control_thread = Thread.new do
          loop do
            peer = server.accept
            begin
              _pid, uid, = peer.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).unpack('iii')
              request = Timeout.timeout(5) { peer.gets(8193) }
              raise KbRuntime::Error, 'invalid control peer/request' unless uid == Process.uid && request && request.bytesize <= 8192
              value = JSON.parse(request)
              expected = { 'schema' => 1, 'instance_id' => opts[:instance_id], 'run_id' => opts[:run_id], 'command' => 'stop' }
              raise KbRuntime::Error, 'control identity differs' unless value == expected
              first = latch_shutdown.call
              begin
                peer.puts(JSON.generate('schema' => 1, 'run_id' => opts[:run_id], 'accepted' => true))
                peer.flush
              ensure
                signal_trap.call if first
              end
            rescue StandardError
              # Invalid local requests never acquire shutdown authority.
            ensure
              peer.close
            end
          end
        end
        start_tracker = proc do
          Thread.new do
            loop do
              keep_tracking = mutex.synchronize do
                next false unless tracking
                discover.call
                write_processes.call(false)
                true
              end
              break unless keep_tracking
              sleep 0.05
            end
          end
        end
        tracking_thread = start_tracker.call

        begin
          Thread.handle_interrupt(ShutdownRequested => :immediate) do
            start_machines(machines, opts[:timeout])
            publish.call
            state.write(state.path("run-#{opts[:run_id]}.json"), launch.merge('processes' => state.read(process_path)), immutable: true)
            mutex.synchronize do
              unless stopping
                state.write(ready_path, { 'schema' => 1, 'instance_id' => opts[:instance_id], 'run_id' => opts[:run_id],
                  'artifact_id' => opts[:artifact_id], 'artifact_sha256' => opts[:artifact_sha256] }, immutable: true)
              end
            end
            loop { sleep 2 }
          end
        rescue ShutdownRequested
          # The one owned shutdown is finalized below.
        ensure
          latch_shutdown.call
          Signal.trap('TERM', 'IGNORE')
          Signal.trap('INT', 'IGNORE')
          signal_writer.close unless signal_writer.closed?
          signal_thread.join
          # Nothing can queue another notification after the notifier is joined.
          # Consume an already queued one without replacing a primary failure.
          begin
            Thread.handle_interrupt(ShutdownRequested => :immediate) { Thread.pass }
          rescue ShutdownRequested
            # Drain remains protected by the surrounding narrow mask.
          end

          publish.call
          @started_machines.reverse_each do |entry|
            next unless entry.machine.running?
            begin
              warn "Stopping #{entry.name}"
              entry.machine.stop(timeout: opts[:timeout])
            rescue StandardError => error
              warn "Graceful stop failed for #{entry.name}: #{error.class}: #{error.message}"
              # Never repeat stop: the original reaper retains the machine.
            end
          end
          finalized = false
          loop do
            @started_machines.each do |entry|
              next unless entry.machine.running?
              begin
                entry.machine.join(timeout: [opts[:timeout], 1].min)
              rescue StandardError => error
                warn "Reaper wait failed for #{entry.name}: #{error.class}: #{error.message}"
              end
            end
            exited = mutex.synchronize do
              observed = discover.call
              write_processes.call(false)
              observed && @started_machines.none? { |entry| entry.machine.running? } && children.values.all? { |record| KbRuntime::ProcessIdentity.gone?(record) }
            end
            unless exited
              sleep 0.05
              next
            end
            mutex.synchronize { tracking = false }
            tracking_thread.join
            quiesced = mutex.synchronize do
              observed = discover.call
              write_processes.call(false)
              observed && @started_machines.none? { |entry| entry.machine.running? } && children.values.all? { |record| KbRuntime::ProcessIdentity.gone?(record) }
            end
            unless quiesced
              mutex.synchronize { tracking = true }
              tracking_thread = start_tracker.call
              next
            end
            unless finalized
              @started_machines.each do |entry|
                begin
                  entry.machine.finalize
                  entry.machine.cleanup
                rescue StandardError => error
                  warn "Cleanup failed for #{entry.name}: #{error.class}: #{error.message}"
                end
              end
              finalized = true
            end
            complete = mutex.synchronize do
              observed = discover.call
              proved = observed && @started_machines.none? { |entry| entry.machine.running? } && children.values.all? { |record| KbRuntime::ProcessIdentity.gone?(record) }
              write_processes.call(proved)
              proved
            end
            break if complete
            mutex.synchronize { tracking = true }
            tracking_thread = start_tracker.call
          end
          control_thread.kill
          control_thread.join
          server.close
          File.unlink(control_path)
          signal_reader.close unless signal_reader.closed?
          raise shutdown_error if shutdown_error && !$!
        end
      end

      0
    end

    def build_machines(opts)
      config = JSON.parse(File.read(opts[:config]))

      config.fetch('machines').map do |name, machine_cfg|
        osvm_cfg = OsVm::MachineConfig.from_config(machine_cfg)
        klass = machine_class(osvm_cfg)

        MachineState.new(
          name: name,
          machine: klass.new(
            name,
            osvm_cfg,
            opts[:state_dir],
            opts[:sock_dir],
            default_timeout: opts[:timeout],
            hash_base:
          ).bind_preparation(@state, @artifact)
        )
      end
    end

    def machine_class(config)
      case config.spin
      when 'nixos'
        KbRuntime::NixosMachine
      when 'vpsadminos'
        KbRuntime::VpsadminosMachine
      else
        raise "Unsupported machine spin #{config.spin.inspect}"
      end
    end

    def start_machines(machines, timeout)
      priority_names = priority_machines.each_with_index.to_h
      priority, rest = machines.partition { |entry| priority_names.key?(entry.name) }
      priority.sort_by! { |entry| priority_names.fetch(entry.name) }

      start_machine_group(priority, timeout)
      start_machine_group(rest, timeout)
    end

    def start_machine_group(machines, timeout)
      machines.each do |entry|
        warn "Starting #{entry.name}"
        @started_machines << entry
        entry.machine.start(wait_for_boot: false)
      end

      machines.each do |entry|
        warn "Waiting for #{entry.name}"
        entry.machine.wait_for_boot(timeout:)
      end
    end
  end
end
