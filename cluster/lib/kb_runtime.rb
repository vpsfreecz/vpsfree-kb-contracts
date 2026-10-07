# frozen_string_literal: true

require 'timeout'
require 'socket'
require 'shellwords'
require 'base64'
require_relative 'kb_state'
require_relative 'kb_process'
require_relative 'kb_resources'
require_relative 'kb_source'
require_relative 'kb_closure'
require_relative 'kb_disks'

module KbRuntime
  class Engine
    attr_reader :state, :software, :resources, :controller

    def initialize(state:, software:, controller:, resources: Resources.new(state))
      @state, @software, @controller, @resources = state, software, controller, resources
    end

    def phase
      state.identity
      state.read(state.path('phase.json'))
    end

    def launch
      record = phase
      launch_path = state.path("launch-#{record.fetch('run_id')}.json")
      value = state.read(File.exist?(launch_path) ? launch_path : state.path("reservation-#{record.fetch('run_id')}.json"))
      validate_launch(value, record.fetch('run_id'))
    end

    def validate_launch(value, run_id)
      identity = state.identity
      unless value['instance_id'] == identity['instance_id'] && value['state_root'] == state.root && value['slug'] == state.slug && value['owner_uid'] == Process.uid && value['run_id'] == run_id
        raise Error, 'foreign launch receipt'
      end
      value
    end

    def set_phase(name, run_id)
      state.write(state.path('phase.json'), { 'schema' => 1, 'phase' => name, 'run_id' => run_id })
    end

    def requested(config, topology, network, identity, run_id)
      machines = ['services', *config.fetch('topologies').fetch(topology)]
      machines += config.fetch('dns', {}).fetch('servers', {}).keys if config.dig('dns', 'enable')
      endpoints = machines.to_h do |name|
        settings = name == 'services' ? config.fetch('services') : config.fetch('nodes', {})[name] || config.fetch('dns').fetch('servers').fetch(name)
        host = network == 'bridge' ? settings.fetch('ip') : config.fetch('local').fetch('bindAddress')
        IPAddr.new(host)
        port = network == 'bridge' ? 22 : config.fetch('local').fetch('ports').fetch(name).fetch('ssh')
        raise Error, 'invalid SSH forwarding port' unless port.is_a?(Integer) && (1..65_535).cover?(port)
        [name, { 'host' => host, 'port' => port, 'user' => 'root' }]
      end
      claims = if network == 'bridge'
                 raise Error, 'bridge config must explicitly declare dedicated addresses' unless config.dig('network', 'dedicated') == true
                 endpoints.values.map { |endpoint| { 'kind' => 'bridge-address', 'bridge' => config.fetch('network').fetch('bridge'), 'address' => endpoint['host'] } }
               else
                 endpoints.values.map { |endpoint| { 'kind' => 'tcp', 'host' => endpoint['host'], 'port' => endpoint['port'] } }
               end
      if network == 'local'
        multicast = config.fetch('local').fetch('multicastPort', nil)
        raise Error, 'local.multicastPort must be an integer in 1..65535' unless multicast.is_a?(Integer) && (1..65_535).cover?(multicast)
        https = config.fetch('local').fetch('ports').fetch('services').fetch('https')
        raise Error, 'invalid HTTPS forwarding port' unless https.is_a?(Integer) && (1..65_535).cover?(https)
        claims << { 'kind' => 'tcp', 'host' => config.fetch('local').fetch('bindAddress'), 'port' => https }
        claims << { 'kind' => 'udp', 'host' => '0.0.0.0', 'port' => multicast }
      end
      network_id = "kb-#{identity.fetch('instance_id')}-#{run_id}"
      socket_dir = resources.socket_dir(identity.fetch('instance_id'), run_id)
      identity.merge('run_id' => run_id, 'boot_id' => ProcessIdentity.boot_id, 'topology' => topology,
                     'network' => network, 'network_id' => network_id, 'resource_claims' => claims.sort_by { |claim| JSON.generate(claim) },
                     'socket_dir' => socket_dir, 'state_dir' => state.path('disks'), 'endpoints' => endpoints,
                     'multicast' => network == 'local' ? { 'address' => '230.0.0.1', 'bind_address' => '0.0.0.0', 'port' => multicast } : nil)
    end

    def initialize_credentials(config)
      directory = state.path('credentials')
      if state.private_directory(directory)
        %w[id_ed25519 id_ed25519.pub known_hosts vpsadmin-ca.crt vpsadmin-ca.key vpsadmin-cert.crt vpsadmin-cert.key].each do |name|
          state.file(File.join(directory, name))
        end
        return directory
      end
      state.private_directory(directory, create: true)
      File.open(File.join(directory, 'known_hosts'), File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
      Software.command('ssh-keygen', '-t', 'ed25519', '-N', '', '-f', File.join(directory, 'id_ed25519'))
      Software.command('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
                       '-keyout', File.join(directory, 'vpsadmin-ca.key'), '-out', File.join(directory, 'vpsadmin-ca.crt'),
                       '-subj', '/CN=vpsfree-kb-instance-ca')
      names = (config.fetch('domains').values + config.fetch('tmpDomains', {}).values).uniq
      raise Error, 'invalid TLS hostname' unless names.all? { |name| /\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/.match?(name) }
      extension = File.join(directory, 'tls.ext')
      File.write(extension, "subjectAltName=#{names.map { |name| "DNS:#{name}" }.join(',')}\n")
      Software.command('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', File.join(directory, 'vpsadmin-cert.key'),
                       '-out', File.join(directory, 'tls.csr'), '-subj', "/CN=#{config.fetch('domains').fetch('webui')}")
      Software.command('openssl', 'x509', '-req', '-in', File.join(directory, 'tls.csr'),
                       '-CA', File.join(directory, 'vpsadmin-ca.crt'), '-CAkey', File.join(directory, 'vpsadmin-ca.key'),
                       '-CAcreateserial', '-out', File.join(directory, 'vpsadmin-cert.crt'), '-days', '3650', '-extfile', extension)
      Dir.children(directory).each { |name| File.chmod(0o600, File.join(directory, name)) }
      directory
    end

    def start(config:, topology: 'single', network: 'bridge', timeout: 900)
      state.transaction(create: true, wait: false) do
        identity = state.initialize_identity
        raise Error, 'start requires a fresh instance; use resume or the recorded update' if File.exist?(state.path('phase.json'))
        run_id = SecureRandom.uuid
        requested(config, topology, network, identity, run_id)
        set_phase('preparing', run_id)
        credentials = initialize_credentials(config)
        candidate = software.prepare(state, identity, config, topology:, network:, credentials:)
        artifact = build_artifact(candidate, credentials, run_id)
        start_locked(artifact, run_id:, timeout:, initial: true)
      end
    end

    def build_artifact(candidate, credentials, run_id)
      state.write(state.path("candidate-#{candidate.fetch('artifact_id')}.json"), candidate, immutable: true)
      set_phase('building', run_id)
      path = state.path("artifact-#{candidate.fetch('artifact_id')}.json")
      return state.read(path) if File.exist?(path)

      artifact = software.build(state, candidate, credentials)
      state.write(path, artifact, immutable: true)
      artifact
    end

    def artifact(record)
      path = state.path("artifact-#{record.fetch('artifact_id')}.json")
      bytes = state.file(path)
      raise Error, 'prepared artifact digest differs' unless Digest::SHA256.hexdigest(bytes) == record.fetch('artifact_sha256')
      value = JSON.parse(bytes)
      unless value['schema'] == 1 && value['instance_id'] == state.identity['instance_id'] && value['artifact_id'] == record['artifact_id']
        raise Error, 'foreign prepared artifact'
      end
      value
    end

    def artifact_digest(value)
      Digest::SHA256.hexdigest(state.file(state.path("artifact-#{value.fetch('artifact_id')}.json")))
    end

    def validate_prepared(value)
      raise Error, 'selected committed source differs from prepared artifact' unless software.metadata == value.fetch('source')
      raise Error, 'retained credentials differ' unless Software.credentials_identity(state.path('credentials')) == value.fetch('credential_identity')
      raise Error, 'built configuration differs' unless Digest::SHA256.file(value.fetch('config_path')).hexdigest == value.fetch('config_sha256')
      proof = state.read(state.path("prepared-#{value.fetch('artifact_id')}.json"))
      unless proof['complete'] == true && proof['instance_id'] == value['instance_id'] && proof['artifact_id'] == value['artifact_id'] && proof['layout'] == value['layout']
        raise Error, 'incomplete artifact preparation'
      end
      input = state.read(value.fetch('input_path'))
      inputs = value.fetch('build_inputs').merge('config' => input)
      unless Digest::SHA256.hexdigest(Software.canonical_json(inputs)) == value.fetch('config_input_sha256')
        raise Error, 'recorded artifact inputs differ'
      end
      if proof['kind'] == 'import'
        value.fetch('layout').each do |machine, layout|
          next unless layout['spin'] == 'nixos'
          imported = state.read(state.path("prepared-#{value.fetch('artifact_id')}-#{machine}.json"))
          unless imported['complete'] == true && imported['instance_id'] == value['instance_id'] && imported['artifact_id'] == value['artifact_id'] &&
                 imported['artifact_sha256'] == artifact_digest(value) && imported['machine'] == machine &&
                 imported['toplevel'] == value.fetch('machine_toplevels').fetch(machine)
            raise Error, 'incomplete machine closure preparation'
          end
        end
      elsif proof['kind'] != 'initial'
        raise Error, 'unsupported artifact preparation'
      end
      disks = DiskPreparation.new(state, value)
      value.fetch('layout').each_key { |machine| disks.validate(machine) }
    end

    def resume(timeout: 900)
      state.transaction(wait: false) do
        raise Error, 'pending update must be retried explicitly' if File.exist?(state.path('update.json'))
        raise Error, 'resume requires proven stopped state' unless phase['phase'] == 'stopped' && gone?(launch)
        accepted = state.read(state.path('accepted-artifact.json'))
        value = artifact(accepted)
        validate_prepared(value)
        start_locked(value, run_id: SecureRandom.uuid, timeout:)
      end
    end

    def update(config:, topology:, network:, timeout: 900)
      state.transaction(wait: false) do
        old = launch
        identity = state.identity
        replacement = requested(config, topology, network, identity, SecureRandom.uuid)
        endpoints = ->(record) { record.fetch('endpoints').transform_values { |endpoint| endpoint.slice('host', 'port') } }
        unless endpoints.call(replacement) == endpoints.call(old)
          raise Error, 'update requires unchanged SSH endpoints for retained host-key trust'
        end
        if File.exist?(state.path('update.json'))
          operation = state.read(state.path('update.json'))
          candidate = state.read(state.path("candidate-#{operation.fetch('artifact_id')}.json"))
          unless candidate.fetch('source') == software.metadata && candidate.fetch('build_inputs').fetch('config') == config &&
                 candidate['topology'] == topology && candidate['network'] == network
            raise Error, 'different candidate cannot replace the retained update'
          end
        else
          raise Error, 'an unprepared update requires a live ready predecessor' unless ready?(old)
          verify_live(old)
          previous = artifact(old)
          credentials = state.path('credentials')
          candidate = software.prepare(state, identity, config, topology:, network:, credentials:)
          current_config = state.read(previous.fetch('input_path'))
          unless candidate['layout'] == previous['layout'] && candidate['credential_identity'] == previous['credential_identity'] &&
                 config.fetch('domains') == current_config.fetch('domains') && config.fetch('tmpDomains', {}) == current_config.fetch('tmpDomains', {}) &&
                 config.fetch('services').slice('rootDiskMiB') == current_config.fetch('services').slice('rootDiskMiB')
            raise Error, 'update requires compatible retained disks and TLS identities'
          end
          state.write(state.path("candidate-#{candidate.fetch('artifact_id')}.json"), candidate, immutable: true)
          operation = { 'schema' => 1, 'operation_id' => SecureRandom.uuid, 'instance_id' => identity['instance_id'],
            'old_run_id' => old['run_id'], 'artifact_id' => candidate['artifact_id'],
            'config_input_sha256' => candidate['config_input_sha256'], 'stage' => 'building' }
          state.write(state.path('update.json'), operation)
        end
        predecessor = state.read(state.path("launch-#{operation.fetch('old_run_id')}.json"))
        if %w[building preparing].include?(operation['stage'])
          raise Error, 'predecessor is unavailable for exact closure preparation' unless live?(predecessor)
          verify_live(predecessor)
          set_phase('updating', predecessor['run_id'])
          path = state.path("artifact-#{candidate.fetch('artifact_id')}.json")
          value = File.exist?(path) ? state.read(path) : software.build(state, candidate, state.path('credentials'))
          state.write(path, value, immutable: true) unless File.exist?(path)
          operation['stage'] = 'preparing'
          state.write(state.path('update.json'), operation)
          prepare_closures(predecessor, value)
          operation['stage'] = 'prepared'
          state.write(state.path('update.json'), operation)
        end
        value = state.read(state.path("artifact-#{operation.fetch('artifact_id')}.json"))
        if operation['stage'] == 'prepared'
          stop_locked(predecessor, timeout:)
          operation['stage'] = 'stopped'
          state.write(state.path('update.json'), operation)
        elsif %w[starting verifying].include?(operation['stage'])
          attempted = operation.fetch('run_id')
          reservation = state.path("reservation-#{attempted}.json")
          if File.exist?(reservation)
            launched = state.path("launch-#{attempted}.json")
            replacement = validate_launch(state.read(File.exist?(launched) ? launched : reservation), attempted)
            unless replacement['artifact_id'] == value['artifact_id'] && replacement['artifact_sha256'] == artifact_digest(value)
              raise Error, 'replacement attempt differs from prepared candidate'
            end
            if live?(replacement)
              return await_ready(replacement, value, timeout:, initial: false)
            end
            # stop_locked distinguishes a positively unspawned attempt from a
            # retained ambiguous handoff and never starts a second runner.
            stop_locked(replacement, timeout:)
          else
            raise Error, 'unexpected candidate process without reservation' if File.exist?(state.path("spawn-#{attempted}.json")) || File.exist?(state.path("processes-#{attempted}.json"))
          end
        end
        validate_prepared(value)
        run_id = SecureRandom.uuid
        operation.merge!('stage' => 'starting', 'run_id' => run_id)
        state.write(state.path('update.json'), operation)
        start_locked(value, run_id:, timeout:)
      end
    end

    private

    def prepare_closures(predecessor, value)
      ClosurePreparation.new(self).prepare(predecessor, value)
    end

    # These operations require the public caller's one gate/operation context.
    def start_locked(value, run_id:, timeout:, initial: false)
        identity = state.identity
        config = state.read(value.fetch('input_path'))
        pending = requested(config, value.fetch('topology'), value.fetch('network'), identity, run_id)
        built = value.merge(pending).merge('artifact_sha256' => artifact_digest(value))
        state.write(state.path("reservation-#{run_id}.json"), built, immutable: true)
        set_phase('reserved', run_id)
        resources.claim(built)
        state.write(state.path('accounts.json'), { 'users' => config.fetch('seed').fetch('users') })
        state.private_directory(built['state_dir'], create: true)
        state.private_directory(built['socket_dir'], create: true)
        state.write(state.path("launch-#{run_id}.json"), built, immutable: true)
        set_phase('built', run_id)
        log_path = state.path("runner-#{run_id}.log")
        log = File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        argv = [built.fetch('runner'), 'start', '--config', built['config_path'], '--state-dir', built['state_dir'],
                '--sock-dir', built['socket_dir'], '--instance-id', built['instance_id'], '--run-id', run_id,
                '--artifact-id', built['artifact_id'], '--artifact-sha256', built['artifact_sha256'],
                '--launch-file', state.path("launch-#{run_id}.json"), '--state-root', state.root, '--slug', state.slug,
                '--timeout', timeout.to_s]
        handoff = state.path("spawn-#{run_id}.json")
        state.write(handoff, { 'schema' => 1, 'run_id' => run_id, 'artifact_id' => built['artifact_id'],
          'artifact_sha256' => built['artifact_sha256'], 'argv' => argv, 'stage' => 'planned' })
        begin
          ruby_environment = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH].to_h { |name| [name, nil] }
          pid = Process.spawn(ruby_environment, *argv, in: File::NULL, out: log, err: log, close_others: true)
        rescue SystemCallError
          state.write(handoff, { 'schema' => 1, 'run_id' => run_id, 'stage' => 'failed-before-spawn' })
          raise
        end
        state.write(handoff, { 'schema' => 1, 'run_id' => run_id, 'artifact_id' => built['artifact_id'],
          'artifact_sha256' => built['artifact_sha256'], 'stage' => 'spawned', 'process' => ProcessIdentity.read(pid) })
        Process.detach(pid)
        log.close
        set_phase('starting', run_id)
        await_ready(built, value, timeout:, initial:)
    ensure
      log&.close unless log&.closed?
    end

    def await_ready(built, value, timeout:, initial:)
        run_id = built.fetch('run_id')
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          ready = state.path("ready-#{run_id}.json")
          if File.exist?(ready)
            ready_record = state.read(ready)
            raise Error, 'foreign readiness receipt' unless ready_record['schema'] == 1 && %w[instance_id run_id artifact_id artifact_sha256].all? { |key| ready_record[key] == built[key] } && live?(built)
            set_phase('verifying', run_id)
            establish_ssh_trust(built, deadline:)
            verify_live(built)
            refresh(built)
            if initial
              disks = DiskPreparation.new(state, value)
              value.fetch('layout').each_key { |machine| disks.validate(machine) }
              state.write(state.path("prepared-#{built['artifact_id']}.json"), { 'schema' => 1,
                'instance_id' => built['instance_id'], 'artifact_id' => built['artifact_id'],
                'layout' => value['layout'], 'complete' => true, 'kind' => 'initial' })
            end
            state.write(state.path('accepted-artifact.json'), built.slice('artifact_id', 'artifact_sha256'))
            set_phase('ready', run_id)
            raise Error, 'readiness withdrawn during verification' unless ready?(built)
            state.write(state.path('connection.json'), descriptor(built))
            File.unlink(state.path('update.json')) if File.exist?(state.path('update.json'))
            return descriptor(built)
          end
          raise Error, 'runner exited before readiness; retained run needs owned stop' if File.exist?(state.path("processes-#{run_id}.json")) && !live?(built)
          raise Error, 'readiness deadline reached; run and claims retained' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.1
        end
    end

    public

    def process_record(record)
      path = state.path("processes-#{record.fetch('run_id')}.json")
      value = state.read(path)
      unless %w[instance_id run_id artifact_id artifact_sha256].all? { |key| value[key] == record[key] }
        raise Error, 'foreign process receipt'
      end
      value
    end

    def live?(record)
      ProcessIdentity.runner_matches?(process_record(record).fetch('runner'), record)
    rescue Errno::ENOENT
      false
    end

    # Readiness is a guarded snapshot, distinct from process ownership/liveness.
    def ready?(record = launch)
      current = phase
      return false unless current['phase'] == 'ready'

      validate_launch(record, current.fetch('run_id'))
      raise Error, 'readiness launch differs' unless launch == record
      begin
        marker = state.read(state.path("ready-#{record.fetch('run_id')}.json"))
      rescue Errno::ENOENT
        return false
      end
      unless marker['schema'] == 1 && %w[instance_id run_id artifact_id artifact_sha256].all? { |key| marker[key] == record[key] }
        raise Error, 'foreign readiness receipt'
      end
      live?(record)
    end

    def gone?(record)
      proof = process_record(record)
      proof.fetch('complete') == true && [proof.fetch('runner'), *proof.fetch('children')].all? { |process| ProcessIdentity.gone?(process) }
    end

    def control(record, command)
      handoff = pin_shutdown_paths(record)
      handoff[:runner] = process_record(record).fetch('runner')
      raise Error, 'runner identity does not match; no signal was sent' unless ProcessIdentity.runner_matches?(handoff[:runner], record)
      socket = UNIXSocket.new(handoff.fetch(:path))
      pid, uid, = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).unpack('iii')
      raise Error, 'foreign runner control peer' unless uid == Process.uid && pid == handoff[:runner].fetch('pid') && ProcessIdentity.runner_matches?(handoff[:runner], record)
      raise Error, 'runner launch changed before stop request' unless launch == record && process_record(record).fetch('runner') == handoff[:runner]
      check_shutdown_paths(handoff, required: true)
      set_phase('stopping', record.fetch('run_id'))
      socket.puts(JSON.generate('schema' => 1, 'instance_id' => record['instance_id'], 'run_id' => record['run_id'], 'command' => command))
      response = Timeout.timeout(5) { socket.gets(8193) }
      raise Error, 'invalid runner control response' unless response && response.bytesize <= 8192 && JSON.parse(response) == { 'schema' => 1, 'run_id' => record['run_id'], 'accepted' => true }
      socket.close
      socket = nil
      accepted = true
      handoff
    ensure
      socket&.close
      close_shutdown_paths(handoff) unless accepted
    end
    private :control

    def stop(timeout: 120)
      state.transaction(wait: false) do
        if %w[preparing building].include?(phase['phase']) && !File.exist?(state.path('update.json'))
          run_id = phase.fetch('run_id')
          raise Error, 'unexpected spawn during artifact preparation' if File.exist?(state.path("spawn-#{run_id}.json"))
          set_phase('stopped', run_id)
          return
        end
        record = launch
        stop_locked(record, timeout:)
      end
    end

    private

    # Linux O_PATH pins the filesystem socket inode, unlike a connected socket.
    # These nonserializable descriptors belong only to this locked invocation.
    def pin_shutdown_paths(record)
      validate_launch(record, record.fetch('run_id'))
      raise Error, 'runner launch changed before stop request' unless launch == record
      directory = record.fetch('socket_dir')
      raise Error, 'socket path differs from recorded namespace' unless directory == resources.socket_dir(record['instance_id'], record['run_id'])
      state.private_directory(directory) || raise(Error, 'runner socket directory is absent')
      handoff = { launch: record, directory: directory, path: File.join(directory, 'control.sock'), absent: false }
      handoff[:directory_fd] = File.open(directory, File::RDONLY | File::NOFOLLOW | 0x10000 | 0x80000) # O_DIRECTORY | O_CLOEXEC
      handoff[:directory_fd].close_on_exec = true
      handoff[:socket_fd] = File.open(handoff[:path], 0x200000 | File::NOFOLLOW | 0x80000) # O_PATH | O_CLOEXEC
      handoff[:socket_fd].close_on_exec = true
      check_shutdown_paths(handoff, required: true)
      pinned = true
      handoff
    ensure
      close_shutdown_paths(handoff) unless pinned
    end

    def shutdown_identity(stat, type, mode)
      raise Error, 'unsafe shutdown socket metadata' unless stat.ftype == type && stat.uid == Process.uid && (stat.mode & 0o7777) == mode
      [stat.dev, stat.ino, stat.ftype, stat.uid, stat.mode & 0o7777]
    end

    def check_shutdown_paths(handoff, required: false)
      directory = handoff.fetch(:directory)
      state.private_directory(directory) || raise(Error, 'runner socket directory disappeared')
      opened = shutdown_identity(handoff.fetch(:directory_fd).stat, 'directory', 0o700)
      named = shutdown_identity(File.lstat(directory), 'directory', 0o700)
      raise Error, 'runner socket directory changed' unless opened == named
      socket = shutdown_identity(handoff.fetch(:socket_fd).stat, 'socket', 0o600)
      begin
        named_socket = shutdown_identity(File.lstat(handoff.fetch(:path)), 'socket', 0o600)
      rescue Errno::ENOENT
        raise Error, 'runner control socket disappeared before stop request' if required
        handoff[:absent] = true
        return false
      end
      raise Error, 'runner control socket changed' if handoff[:absent] || socket != named_socket
      true
    end

    def check_shutdown_exit(handoff, record)
      proof = process_record(record)
      unless launch == handoff.fetch(:launch) && proof.fetch('runner') == handoff.fetch(:runner) && proof.fetch('complete') == true && [proof.fetch('runner'), *proof.fetch('children')].all? { |process| ProcessIdentity.gone?(process) }
        raise Error, 'shutdown handoff lacks unchanged complete exit proof'
      end
    end

    def retire_shutdown_socket(handoff, record)
      check_shutdown_exit(handoff, record)
      present = check_shutdown_paths(handoff)
      entries = Dir.children(handoff.fetch(:directory))
      raise Error, 'unrecognized retained socket contents; no handoff deletion' unless entries.empty? || (present && entries == ['control.sock'])
      if present
        # Check again after the complete inventory, immediately before unlink.
        File.unlink(handoff.fetch(:path)) if check_shutdown_paths(handoff)
      end
    end

    def close_shutdown_paths(handoff)
      return unless handoff
      %i[socket_fd directory_fd].each do |name|
        descriptor = handoff[name]
        descriptor.close if descriptor && !descriptor.closed?
      end
    end

    def stop_locked(record, timeout:)
        spawn_path = state.path("spawn-#{record['run_id']}.json")
        before_spawn = !File.exist?(spawn_path) || state.read(spawn_path)['stage'] == 'failed-before-spawn'
        if before_spawn
          raise Error, 'unexpected process receipt before launch' if File.exist?(state.path("processes-#{record['run_id']}.json"))
          resources.release(record, processes_gone: true)
          cleanup_socket(record)
          set_phase('stopped', record['run_id'])
          return
        end
        handoff = control(record, 'stop') if live?(record)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until gone?(record)
          raise Error, 'owned shutdown incomplete; processes, paths and claims retained' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.1
        end
        check_shutdown_exit(handoff, record) if handoff
        resources.release(record, processes_gone: true)
        retire_shutdown_socket(handoff, record) if handoff
        cleanup_socket(record)
        set_phase('stopped', record['run_id'])
    ensure
      close_shutdown_paths(handoff)
    end

    public

    def cleanup_socket(record)
      directory = record.fetch('socket_dir')
      raise Error, 'socket path differs from recorded namespace' unless directory == resources.socket_dir(record['instance_id'], record['run_id'])
      return unless File.exist?(directory) || File.symlink?(directory)
      state.private_directory(directory)
      # Runner removes its own sockets. Unknown leftovers require diagnosis.
      raise Error, 'unrecognized retained socket contents; no recursive deletion' unless Dir.empty?(directory)
      Dir.rmdir(directory)
    end

    def reset
      state.transaction(wait: false) do
        state.identity
        if File.exist?(state.path('phase.json'))
          current = phase
          raise Error, 'stop and prove the owned run before reset' unless current['phase'] == 'stopped'
          if File.exist?(state.path("reservation-#{current.fetch('run_id')}.json"))
            record = launch
            handoff = state.path("spawn-#{record['run_id']}.json")
            unspawned = !File.exist?(handoff) || state.read(handoff)['stage'] == 'failed-before-spawn'
            proved = unspawned ? !File.exist?(state.path("processes-#{record['run_id']}.json")) : gone?(record)
            raise Error, 'stop and prove the owned run before reset' unless proved
            resources.release(record, processes_gone: true)
            cleanup_socket(record)
          elsif File.exist?(state.path("spawn-#{current['run_id']}.json")) || File.exist?(state.path("processes-#{current['run_id']}.json"))
            raise Error, 'unexpected runner without reservation'
          end
        end
        verify_tree(state.directory)
        FileUtils.remove_entry(state.directory)
      end
    end

    def verify_tree(path)
      stat = File.lstat(path)
      raise Error, 'foreign entry in owned cluster tree' unless stat.uid == Process.uid
      if stat.symlink?
        raise Error, 'unknown symlink in owned state' unless File.basename(path).start_with?('result-') && File.realpath(path).start_with?('/nix/store/')
      elsif stat.directory?
        Dir.children(path).each { |name| verify_tree(File.join(path, name)) }
      elsif !stat.file?
        raise Error, 'unknown resource in owned cluster tree'
      end
    end

    def status
      return { 'schema' => 2, 'found' => false, 'state' => 'absent' } unless File.exist?(state.directory) || File.symlink?(state.directory)
      state.transaction(wait: false) do
        identity = state.identity
        record = File.exist?(state.path('phase.json')) ? phase : nil
        { 'schema' => 2, 'found' => true, 'state' => record ? record['phase'] : 'initialized',
          'instance_id' => identity['instance_id'], 'run_id' => record && record['run_id'],
          'ready' => record && record['phase'] == 'ready' && ready?(launch) }
      end
    end

    def descriptor(record = launch)
      state.identity
      config = state.read(record.fetch('input_path'))
      credentials = state.path('credentials')
      https = record['network'] == 'local' ? config.fetch('local').fetch('ports').fetch('services').fetch('https') : 443
      host = record.fetch('endpoints').fetch('services').fetch('host')
      services = config.fetch('domains').transform_values do |domain|
        { 'url' => "https://#{domain}/", 'connect_host' => host, 'connect_port' => https }
      end
      accounts = state.path('accounts.json')
      state.file(accounts)
      { 'schema' => 1, 'kind' => 'vpsfree-kb-connection', 'owner_id' => "uid:#{Process.uid}",
        'instance_id' => record['instance_id'], 'run_id' => record['run_id'], 'topology' => record['topology'],
        'artifact_id' => record['artifact_id'], 'artifact_sha256' => record['artifact_sha256'],
        'capabilities' => capabilities(record),
        'services' => services, 'machines' => record.fetch('endpoints').transform_values { |endpoint| endpoint.merge('private_key' => File.join(credentials, 'id_ed25519'), 'known_hosts' => File.join(credentials, 'known_hosts')) },
        'tls' => { 'ca_file' => File.join(credentials, 'vpsadmin-ca.crt') }, 'accounts_file' => accounts,
        'provenance' => record.slice('source', 'guest_identity', 'config_path', 'config_sha256', 'machine_toplevels', 'runner').merge(
          'artifact' => artifact(record), 'artifact_json' => state.file(state.path("artifact-#{record.fetch('artifact_id')}.json"))),
        'control' => { 'argv' => [*controller, '--state-root', state.root, 'capture-lease', state.slug] } }
    end

    def connection
      state.transaction do
        record = launch
        raise Error, 'cluster is not ready' unless ready?(record)
        state.file(state.path('connection.json'))
      end
    end

    def ssh(record, machine, *command, input: nil)
      endpoint = record.fetch('endpoints').fetch(machine)
      credentials = state.path('credentials')
      argv = ['ssh', '-F', File::NULL, '-i', File.join(credentials, 'id_ed25519'), '-p', endpoint.fetch('port').to_s,
              '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=#{File.join(credentials, 'known_hosts')}",
              '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=5', "root@#{endpoint.fetch('host')}", Shellwords.join(command)]
      environment = ENV.keys.grep(/\A(?:VPSADMIN_(?:DEVCLUSTER|KB)_|NIX_|SSH_)/).to_h { |name| [name, nil] }
      out, _err, result = Open3.capture3(environment, *argv, stdin_data: input || '')
      raise Error, "SSH operation failed on #{machine}" unless result.success?
      out
    end

    def establish_ssh_trust(record, deadline:)
      known = File.join(state.path('credentials'), 'known_hosts')
      retained = state.file(known)
      discovery = SecureRandom.hex(6)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      keys = record.fetch('endpoints').flat_map do |machine, endpoint|
        attempt = 0
        status = 'not-run'
        diagnostic = 'none'
        loop do
          assert_ssh_runner(record)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining < 1
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            raise Error, "SSH discovery deadline on #{machine} #{endpoint['host']}:#{endpoint['port']}; attempts=#{attempt} elapsed=#{elapsed.round(3)} status=#{status} diagnostics=#{diagnostic}"
          end
          attempt += 1
          diagnostic = state.path("ssh-#{record.fetch('run_id')}-#{discovery}-#{machine}-#{attempt}.json")
          begin
            result = ssh_keyscan(endpoint, timeout: [5, remaining.floor].min, deadline:)
          rescue SystemCallError, IOError => error
            result = { stdout: '', stderr: error.message.byteslice(0, 16 * 1024), exitstatus: nil, termsig: nil,
              deadline: false, truncated: error.message.bytesize > 16 * 1024, invocation_error: error.class.name }
          end
          status = result[:invocation_error] || (result[:termsig] ? "signal-#{result[:termsig]}" : "exit-#{result[:exitstatus]}")
          state.write(diagnostic, { 'schema' => 1, 'run_id' => record.fetch('run_id'), 'machine' => machine,
            'endpoint' => endpoint, 'attempt' => attempt, 'elapsed' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
            'exitstatus' => result[:exitstatus], 'termsig' => result[:termsig], 'deadline' => result[:deadline],
            'truncated' => result[:truncated], 'invocation_error' => result[:invocation_error],
            'stdout_base64' => Base64.strict_encode64(result.fetch(:stdout)),
            'stderr_base64' => Base64.strict_encode64(result.fetch(:stderr)) }, immutable: true)
          context = "#{machine} #{endpoint['host']}:#{endpoint['port']}; status=#{status} diagnostics=#{diagnostic}"
          raise Error, "SSH keyscan invocation failed on #{context}" if result[:invocation_error]
          assert_ssh_runner(record)
          raise Error, "SSH discovery deadline on #{context}" if result[:deadline] || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise Error, "SSH keyscan terminated on #{context}" if result[:termsig]
          raise Error, "SSH keyscan output exceeds its bound on #{context}" if result[:truncated]
          begin
            found = ssh_host_keys(result.fetch(:stdout), endpoint)
          rescue Error
            raise Error, "invalid SSH host key data on #{context}"
          end
          if !retained.empty? && !found.all? { |key| retained.lines.include?("#{key}\n") }
            raise Error, "SSH host keys changed; retained trust is not replaced on #{context}"
          end
          break found if result[:exitstatus] == 0 && !found.empty?

          sleep [0.1, [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max].min
        end
      end
      raise Error, 'no dedicated SSH endpoints recorded' if keys.empty?
      assert_ssh_runner(record)
      raise Error, 'SSH discovery deadline before trust publication' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      # First-contact trust is restricted to this explicitly owned fresh launch.
      File.write(known, "#{keys.uniq.join("\n")}\n") if retained.empty?
    end

    def assert_ssh_runner(record)
      validate_launch(record, phase.fetch('run_id'))
      raise Error, 'runner is not the recorded live run during SSH discovery' unless live?(record)
    end

    # This SSH-only child has one waitpid owner, not a detached reaper. Its PID
    # remains signal authority until reaped; no guest or runner is signalled.
    def ssh_keyscan(endpoint, timeout:, deadline:)
      output = output_writer = error = error_writer = pid = status = nil
      environment = ENV.keys.grep(/\A(?:VPSADMIN_(?:DEVCLUSTER|KB)_|NIX_|SSH_)/).to_h { |name| [name, nil] }
      Thread.handle_interrupt(SignalException => :never) do
        output, output_writer = IO.pipe
        error, error_writer = IO.pipe
        pid = Process.spawn(environment, 'ssh-keyscan', '-T', timeout.to_s, '-p', endpoint.fetch('port').to_s,
          endpoint.fetch('host'), in: File::NULL, out: output_writer, err: error_writer, close_others: true)
      end
      streams = { output => ''.b, error => ''.b }
      output_writer.close
      error_writer.close
      pending = streams.keys.dup
      expired = false
      truncated = false
      until status && pending.empty?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0 || truncated
          expired = remaining <= 0
          break
        end
        if pid
          # A successful wait ends signal authority before a pending supported
          # interruption can enter cleanup. ECHILD also invalidates authority.
          Thread.handle_interrupt(SignalException => :never) do
            begin
              waited = Process.waitpid2(pid, Process::WNOHANG)
              if waited
                status = waited.last
                pid = nil
              end
            rescue Errno::ECHILD
              pid = nil
              raise
            end
          end
        end
        next if pending.empty? && status
        readable = IO.select(pending, nil, nil, [0.1, remaining].min)&.first || []
        readable.each do |stream|
          bytes = stream.read_nonblock(4096, exception: false)
          if bytes.nil?
            pending.delete(stream)
          elsif bytes != :wait_readable
            limit = 16 * 1024 - streams.fetch(stream).bytesize
            streams[stream] << bytes.byteslice(0, limit)
            truncated ||= bytes.bytesize > limit
          end
        end
      end
      Thread.handle_interrupt(SignalException => :never) do
        begin
          if pid
            Process.kill('KILL', pid)
            status = Process.waitpid2(pid).last
            pid = nil
          end
        rescue Errno::ECHILD
          pid = nil
          raise
        ensure
          [output, output_writer, error, error_writer].compact.each { |stream| stream.close unless stream.closed? }
        end
      end
      { stdout: streams.fetch(output), stderr: streams.fetch(error), exitstatus: status.exitstatus,
        termsig: status.termsig, deadline: expired, truncated: }
    ensure
      Thread.handle_interrupt(SignalException => :never) do
        begin
          if pid
            Process.kill('KILL', pid)
            status = Process.waitpid2(pid).last
            pid = nil
          end
        rescue Errno::ECHILD
          pid = nil
          raise
        ensure
          [output, output_writer, error, error_writer].compact.each { |stream| stream.close unless stream.closed? }
        end
      end
    end

    def ssh_host_keys(output, endpoint)
      raise Error, 'non-ASCII SSH host key data' unless output.ascii_only?
      host = endpoint.fetch('port') == 22 ? endpoint.fetch('host') : "[#{endpoint.fetch('host')}]:#{endpoint.fetch('port')}"
      output.lines.filter_map do |line|
        next if line.strip.empty? || line.start_with?('#')
        fields = line.split
        raise Error, 'wrong SSH host key endpoint or format' unless fields.length == 3 && fields.first == host
        bytes = Base64.strict_decode64(fields.last)
        parts = []
        until bytes.empty?
          raise Error, 'invalid SSH key length' if bytes.bytesize < 4
          size = bytes.unpack1('N')
          raise Error, 'invalid SSH key field' unless size.positive? && size <= bytes.bytesize - 4
          parts << bytes.byteslice(4, size)
          bytes = bytes.byteslice(4 + size..)
        end
        valid = case fields[1]
                when 'ssh-ed25519' then parts.length == 2 && parts.last.bytesize == 32
                when 'ssh-rsa' then parts.length == 3
                when /\Aecdsa-sha2-nistp(256|384|521)\z/
                  curve = "nistp#{Regexp.last_match(1)}"
                  length = { 'nistp256' => 65, 'nistp384' => 97, 'nistp521' => 133 }.fetch(curve)
                  parts.length == 3 && parts[1] == curve && parts.last.bytesize == length && parts.last.getbyte(0) == 4
                else false
                end
        raise Error, 'invalid SSH host key' unless valid && parts.first == fields[1]
        fields.join(' ')
      end
    rescue ArgumentError
      raise Error, 'invalid SSH host key encoding'
    end

    def verify_live(record)
      raise Error, 'runner is not the recorded live run' unless live?(record)
      artifact(record)
      raise Error, 'configuration bytes differ' unless Digest::SHA256.file(record.fetch('config_path')).hexdigest == record.fetch('config_sha256')
      record.fetch('machine_toplevels').each do |machine, expected|
        identity = JSON.parse(ssh(record, machine, 'cat', '/etc/vpsfree-kb-capture.json'))
        raise Error, 'running source/fixture identity differs' unless identity == record.fetch('guest_identity')
        system = ssh(record, machine, 'readlink', '-f', '/run/current-system').strip
        raise Error, 'running machine closure differs' unless system == expected
      end
      true
    end

    def capabilities(record)
      values = %w[capture-lease-v1 ssh account public-key]
      if record.fetch('endpoints').key?('node1')
        values += %w[ip-inventory base-vps snapshot ssh-host-key nixos-generations traffic-samples kvm-storage]
      end
      values -= %w[base-vps snapshot ssh-host-key nixos-generations traffic-samples kvm-storage] unless record.fetch('endpoints').key?('backuper1')
      values << 'second-vps' if record.fetch('endpoints').key?('node2')
      values
    end

    def refresh(record = launch)
      config = state.read(record.fetch('input_path'))
      pool = config.fetch('seed').fetch('pools').fetch('filesystem')
      raise Error, 'invalid pool filesystem' unless /\A[a-zA-Z0-9_\/-]+\z/.match?(pool)
      seed_wait = <<~SH
        set -eu
        for _ in $(seq 1 180); do
          if systemctl is-active --quiet vpsadmin-api.service && mysql -N -B vpsadmin -e 'SELECT filesystem FROM pools' 2>/dev/null | grep -Fx "$1" >/dev/null; then
            exit 0
          fi
          sleep 1
        done
        echo 'capture pool seed was not ready' >&2
        exit 1
      SH
      ssh(record, 'services', 'sh', '-s', '--', pool, input: seed_wait)
      record.fetch('endpoints').each_key do |machine|
        next unless config.dig('nodes', machine, 'role') == 'node'
        script = <<~SH
          set -eu
          pool_fs="$1"
          pool_name="${pool_fs%%/*}"
          for _ in $(seq 1 180); do
            zpool list -H "$pool_name" >/dev/null 2>&1 && break
            sleep 1
          done
          zpool list -H "$pool_name" >/dev/null
          for ds in "$pool_fs/vpsadmin" "$pool_fs/vpsadmin/config" "$pool_fs/vpsadmin/download" "$pool_fs/vpsadmin/mount"; do
            zfs list -H "$ds" >/dev/null 2>&1 || zfs create -p "$ds"
          done
          mkdir -p "/$pool_fs/vpsadmin/config/vps"
          pool_parent="$(dirname "$pool_fs")"
          [ "$pool_parent" != '.' ] || pool_parent="$pool_fs"
          mkdir -p "/$pool_parent/hook/ct"
          for _ in $(seq 1 180); do
            if test -S /run/osctl/osctld.sock && osctl pool list -H -o name 2>/dev/null | grep -Fx "$pool_name" >/dev/null && osctl --pool "$pool_name" group show /default >/dev/null 2>&1; then break; fi
            sleep 1
          done
          test -S /run/osctl/osctld.sock
          osctl --pool "$pool_name" group show /default >/dev/null
          add_device() {
            error=$(mktemp)
            if ! osctl --pool "$pool_name" group devices add -p /default "$@" 2>"$error"; then
              grep -q 'device already exists' "$error" || { cat "$error" >&2; rm -f "$error"; return 1; }
            fi
            rm -f "$error"
          }
          add_device char 10 200 rwm /dev/net/tun
          add_device char 10 229 rwm /dev/fuse
          add_device char 108 0 rwm /dev/ppp
          add_device char 10 232 rwm /dev/kvm
          sv restart nodectld >/dev/null
          for _ in $(seq 1 90); do
            if sv check nodectld >/dev/null 2>&1 && test -S /run/nodectl/nodectld.sock && nodectl status 2>/dev/null | grep -q 'State: running'; then exit 0; fi
            sleep 1
          done
          echo 'capture node service was not ready' >&2
          exit 1
        SH
        ssh(record, machine, 'sh', '-s', '--', pool, input: script)
      end
    end

    def capture_lease(instance_id:, run_id:, artifact_id:, artifact_sha256:, descriptor_sha256:, input: $stdin, output: $stdout)
      state.lock('gate') do
        state.lock('operation') do
          record = launch
          raise Error, 'capture lease identity differs' unless record['instance_id'] == instance_id && record['run_id'] == run_id &&
            record['artifact_id'] == artifact_id && record['artifact_sha256'] == artifact_sha256
          raise Error, 'cluster is not ready for capture lease' unless ready?(record)
          value = state.file(state.path('connection.json'))
          raise Error, 'descriptor changed' unless Digest::SHA256.hexdigest(value) == descriptor_sha256
          verify_live(record)
          raise Error, 'readiness lost before capture lease response' unless ready?(record)
          output.puts(JSON.generate('schema' => 1, 'instance_id' => instance_id, 'run_id' => run_id,
            'artifact_id' => artifact_id, 'artifact_sha256' => artifact_sha256, 'descriptor_sha256' => descriptor_sha256))
          output.flush
        end
        loop do
          raise Error, 'readiness lost during capture lease' unless ready?(launch)
          next unless IO.select([input], nil, nil, 0.2)
          break if input.read_nonblock(1024, exception: false).nil?
        end
      end
    end
  end
end
