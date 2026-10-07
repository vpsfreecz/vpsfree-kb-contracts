# frozen_string_literal: true

require 'timeout'
require 'socket'
require 'shellwords'
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
      state.transaction(create: true) do
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
      state.transaction do
        raise Error, 'pending update must be retried explicitly' if File.exist?(state.path('update.json'))
        raise Error, 'resume requires proven stopped state' unless phase['phase'] == 'stopped' && gone?(launch)
        accepted = state.read(state.path('accepted-artifact.json'))
        value = artifact(accepted)
        validate_prepared(value)
        start_locked(value, run_id: SecureRandom.uuid, timeout:)
      end
    end

    def update(config:, topology:, network:, timeout: 900)
      state.transaction do
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
          raise Error, 'an unprepared update requires a live ready predecessor' unless phase['phase'] == 'ready'
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
            raise Error, 'foreign readiness receipt' unless %w[instance_id run_id artifact_id artifact_sha256].all? { |key| ready_record[key] == built[key] } && live?(built)
            set_phase('verifying', run_id)
            establish_ssh_trust(built)
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

    def gone?(record)
      proof = process_record(record)
      proof.fetch('complete') == true && [proof.fetch('runner'), *proof.fetch('children')].all? { |process| ProcessIdentity.gone?(process) }
    end

    def control(record, command)
      raise Error, 'runner identity does not match; no signal was sent' unless live?(record)
      socket = UNIXSocket.new(File.join(record.fetch('socket_dir'), 'control.sock'))
      pid, uid, = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).unpack('iii')
      raise Error, 'foreign runner control peer' unless uid == Process.uid && pid == process_record(record).fetch('runner').fetch('pid') && live?(record)
      socket.puts(JSON.generate('schema' => 1, 'instance_id' => record['instance_id'], 'run_id' => record['run_id'], 'command' => command))
      response = Timeout.timeout(5) { socket.gets(8193) }
      raise Error, 'invalid runner control response' unless response && response.bytesize <= 8192 && JSON.parse(response) == { 'schema' => 1, 'run_id' => record['run_id'], 'accepted' => true }
    ensure
      socket&.close
    end

    def stop(timeout: 120)
      state.transaction do
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

    def stop_locked(record, timeout:)
        handoff = state.path("spawn-#{record['run_id']}.json")
        before_spawn = !File.exist?(handoff) || state.read(handoff)['stage'] == 'failed-before-spawn'
        if before_spawn
          raise Error, 'unexpected process receipt before launch' if File.exist?(state.path("processes-#{record['run_id']}.json"))
          resources.release(record, processes_gone: true)
          cleanup_socket(record)
          set_phase('stopped', record['run_id'])
          return
        end
        control(record, 'stop') if live?(record)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until gone?(record)
          raise Error, 'owned shutdown incomplete; processes, paths and claims retained' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.1
        end
        resources.release(record, processes_gone: true)
        cleanup_socket(record)
        set_phase('stopped', record['run_id'])
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
      state.transaction do
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
          'ready' => record && record['phase'] == 'ready' && live?(launch) }
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
        raise Error, 'cluster is not ready' unless phase['phase'] == 'ready' && live?(record)
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

    def establish_ssh_trust(record)
      known = File.join(state.path('credentials'), 'known_hosts')
      retained = state.file(known)
      keys = record.fetch('endpoints').values.map do |endpoint|
        Software.command('ssh-keyscan', '-T', '5', '-p', endpoint.fetch('port').to_s, endpoint.fetch('host'))
      end.join("\n")
      raise Error, 'no dedicated SSH host keys received' if keys.empty?
      # First-contact trust is restricted to this explicitly owned fresh launch.
      if retained.empty?
        File.write(known, "#{keys}\n")
      else
        raise Error, 'SSH host keys changed; retained trust is not replaced' unless keys.lines.all? { |key| retained.lines.include?("#{key.strip}\n") }
      end
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
        values += %w[base-vps snapshot ssh-host-key nixos-generations traffic-samples kvm-storage]
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
            record['artifact_id'] == artifact_id && record['artifact_sha256'] == artifact_sha256 && phase['phase'] == 'ready'
          value = state.file(state.path('connection.json'))
          raise Error, 'descriptor changed' unless Digest::SHA256.hexdigest(value) == descriptor_sha256
          verify_live(record)
          output.puts(JSON.generate('schema' => 1, 'instance_id' => instance_id, 'run_id' => run_id,
            'artifact_id' => artifact_id, 'artifact_sha256' => artifact_sha256, 'descriptor_sha256' => descriptor_sha256))
          output.flush
        end
        loop do
          raise Error, 'runner lost during capture lease' unless live?(launch)
          next unless IO.select([input], nil, nil, 0.2)
          break if input.read_nonblock(1024, exception: false).nil?
        end
      end
    end
  end
end
