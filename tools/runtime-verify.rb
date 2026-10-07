#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'open3'
require 'shellwords'
require_relative '../cluster/lib/kb_source'
require_relative 'capture-export'

module KbVerify
  Error = Class.new(StandardError)
  PHASES = %w[installed-layout runtime-smoke bilingual-capture].freeze
  KIND = 'single-runtime-v1'
  CREDENTIALS = %w[id_ed25519 id_ed25519.pub vpsadmin-ca.crt vpsadmin-ca.key vpsadmin-cert.crt vpsadmin-cert.key].freeze
  GIB = 1024**3

  class Commands
    attr_reader :environment

    def initialize(selection, root)
      @root = root
      environment = ENV.to_h.slice('HOME', 'USER', 'LOGNAME', 'XDG_RUNTIME_DIR')
      if environment['XDG_RUNTIME_DIR']
        directory = environment.fetch('XDG_RUNTIME_DIR')
        KbRuntime::State.new(directory, 'runtime-check').private_directory(directory)
      end
      @environment = environment.merge('PATH' => selection.fetch('path'), 'LANG' => 'C.UTF-8',
        'TMPDIR' => File.join(root, 'temporary'), 'NODE_PATH' => selection.fetch('node_path'),
        'PLAYWRIGHT_BROWSERS_PATH' => selection.fetch('browsers'), 'FONTCONFIG_FILE' => selection.fetch('fonts'),
        'NIX_SSL_CERT_FILE' => selection.fetch('certificates'), 'SSL_CERT_FILE' => selection.fetch('certificates'),
        'GEM_HOME' => selection.fetch('gem_home'), 'GEM_PATH' => selection.fetch('gem_home'),
        'NIX_CONFIG' => "experimental-features = nix-command flakes\nextra-substituters = https://cache.vpsadminos.org\nextra-trusted-public-keys = cache.vpsadminos.org:wpIJlNZQIhS+0gFf1U3MC9sLZdLW3sh5qakOWGDoDrE=\nmax-jobs = 1\ncores = 1\n")
    end

    def call(argv, cwd:, accepted: [0], input: '', stage: nil)
      state = KbRuntime::State.new(@root, 'diagnostics')
      state.private_directory(@root) || raise(Error, 'command campaign root is absent')
      directory = File.join(@root, 'diagnostics')
      state.private_directory(directory, create: true)
      directory = File.join(directory, SecureRandom.hex(12))
      state.private_directory(directory, create: true)
      record = { 'schema' => 1, 'argv' => argv, 'cwd' => cwd, 'stage' => stage,
        'owner_uid' => Process.uid, 'started_at' => Time.now.utc.iso8601, 'complete' => false }
      native = File.join(directory, 'command.json')
      reader, writer = IO.pipe
      output = File.open(File.join(directory, 'stdout'), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
      error = File.open(File.join(directory, 'stderr'), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
      status = nil
      pid = nil
      Thread.handle_interrupt(SignalException => :never) do
        pid = Process.spawn(environment, *argv, chdir: cwd, in: reader, out: output, err: error,
          unsetenv_others: true, close_others: true)
        record['pid'] = pid
      end
      reader.close
      state.write(native, record)
      writer.write(input)
      writer.close
      loop do
        # This is the sole reaper. Record the result and clear authority together
        # before an interrupt can signal an already-reaped/reused process ID.
        Thread.handle_interrupt(SignalException => :never) do
          result = Process.waitpid2(pid, Process::WNOHANG)
          if result
            status = result.last
            pid = nil
          end
        end
        break if status
        sleep 0.05
      end
      record.merge!('complete' => true, 'exit_code' => status.exitstatus, 'signal' => status.termsig,
        'accepted' => accepted.include?(status.exitstatus), 'finished_at' => Time.now.utc.iso8601)
      state.write(native, record)
      raise Error, "verification command refused (#{status.exitstatus || "signal #{status.termsig}"}); private diagnostics: #{native}" unless record['accepted']
      [File.binread(File.join(directory, 'stdout')), File.binread(File.join(directory, 'stderr')), status.exitstatus]
    rescue SignalException
      Thread.handle_interrupt(SignalException => :never) do
        status = reap_interrupted(pid) if pid
        pid = nil
        record.merge!('interrupted' => true, 'complete' => !status.nil?, 'exit_code' => status&.exitstatus,
          'signal' => status&.termsig, 'cleanup_scope' => 'spawned public command only', 'finished_at' => Time.now.utc.iso8601)
        state.write(native, record)
      end
      raise
    rescue StandardError => failure
      raise unless native && record
      Thread.handle_interrupt(SignalException => :never) do
        status = reap_interrupted(pid) if pid
        pid = nil
        unless record['complete']
          record.merge!('failure_class' => failure.class.name, 'failure_message' => failure.message,
            'complete' => !status.nil?, 'exit_code' => status&.exitstatus, 'signal' => status&.termsig,
            'finished_at' => Time.now.utc.iso8601)
          state.write(native, record)
        end
      end
      raise Error, "verification command failed; private diagnostics: #{native}"

    ensure
      [reader, writer, output, error].compact.each { |stream| stream.close unless stream.closed? }
    end

    def reap_interrupted(pid)
      # The sole parent/reaper retains PID authority until its own wait. These
      # signals do not certify exit of a daemon builder or a detached VM runner.
      Process.kill('TERM', pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        result = Process.waitpid2(pid, Process::WNOHANG)
        return result.last if result
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Process.kill('KILL', pid)
          return Process.waitpid2(pid).last
        end
        sleep 0.05
      end
    end

  end

  class Campaign
    attr_reader :root, :selection, :source, :commands, :config, :inputs, :assertions

    def initialize(root:, config:, capacity_receipt:, selection:, commands: nil)
      @root, @selection = File.expand_path(root), selection
      @source = KbRuntime::Software.new(JSON.parse(File.read(selection.fetch('metadata')))).metadata
      raise Error, 'verifier source must be its own immutable package source' unless
        source.fetch('source') == selection.fetch('source') && File.expand_path('..', __dir__) == source.fetch('source')
      raise Error, 'selected runtime metadata differs' unless
        File.read(File.join(selection.fetch('runtime'), 'bin/vpsfree-kb-devcluster')).include?(selection.fetch('metadata'))
      @state = KbRuntime::State.new(@root, 'campaign')
      @config_bytes = @state.file(File.expand_path(config))
      @config = JSON.parse(@config_bytes)
      validate_config(@config)
      @capacity_receipt = File.expand_path(capacity_receipt)
      @inputs = { 'kind' => KIND, 'source' => source, 'selection' => selection, 'configuration' => @config,
        'configuration_sha256' => Digest::SHA256.hexdigest(@config_bytes), 'root' => @root,
        'capacity_receipt' => @capacity_receipt }
      @commands = commands || Commands.new(selection, @root)
      @assertions = []
    end

    def validate_config(config)
      users = config.fetch('seed').fetch('users')
      raise Error, 'inventory verification requires explicit account entries' unless users.is_a?(Array)
      [['test-admin', 99, 1], ['test-user1', 1, 9], ['test-user2', 1, 17]].each do |login, level, block_start|
        matches = users.select { |entry| entry['login'] == login }
        raise Error, 'missing or duplicate inventory account' unless matches.size == 1
        account = matches.first
        unless account['level'] == level && account['password'].is_a?(String) && !account['password'].empty? &&
            account['fullName'].is_a?(String) && !account['fullName'].strip.empty? && account['email'] == "#{login}@example.test" &&
            account['namespace'] == { 'blockStart' => block_start, 'blockCount' => 8 }
          raise Error, 'inventory account role, identity or namespace differs'
        end
      end
      unless config.dig('services', 'memoryMiB') == 2048 && config.dig('services', 'rootDiskMiB') == 8192 &&
          config.fetch('nodes').keys == ['node1'] && config.dig('nodes', 'node1', 'memoryMiB') == 2048 &&
          config.dig('nodes', 'node1', 'tankDiskGiB') == 8 && config.dig('topologies', 'single') == ['node1'] &&
          config.dig('dns', 'enable') == false && config.dig('resolver', 'mode') == 'cluster' &&
          config.dig('resolver', 'upstreamNameservers') == ['10.0.2.3']
        raise Error, 'verification requires the explicit two-2-GiB-guest/8-GiB-image-root-tank configuration'
      end
      %w[domains tmpDomains].each do |name|
        raise Error, 'verification TLS domains must use example.test' unless config.fetch(name).values.all? { |domain| domain.end_with?('.example.test') }
      end
      local = config.fetch('local')
      tcp = local.fetch('ports').values.flat_map(&:values)
      values = [local.fetch('multicastPort'), *tcp]
      unless local['bindAddress'] == '127.0.0.1' && local.fetch('ports').keys.sort == %w[node1 services] &&
          local.fetch('ports').fetch('services').keys.sort == %w[https ssh] && local.fetch('ports').fetch('node1').keys == ['ssh'] &&
          values.all? { |port| port.is_a?(Integer) && port.between?(1, 65535) } && tcp.uniq == tcp
        raise Error, 'verification requires explicit dedicated loopback TCP and multicast UDP ports'
      end
    end

    def check(condition, name)
      raise Error, "assertion failed: #{name}" unless condition
      assertions << name
    end

    def file(name)
      File.join(root, name)
    end

    def read(name)
      @state.read(file(name))
    end

    def write(name, value, immutable: false)
      @state.write(file(name), value, immutable:)
    end

    def initialize_campaign
      identity = nil
      if File.exist?(root)
        @state.private_directory(root)
        if File.exist?(file('campaign.json'))
          identity = read('campaign.json')
          unless identity['schema'] == 1 && identity['kind'] == KIND && identity['owner_uid'] == Process.uid &&
              identity['root'] == File.realpath(root) && identity['inputs'] == inputs
            raise Error, 'campaign kind, identity, selected packages or inputs differ'
          end
        elsif !Dir.empty?(root)
          raise Error, 'nonempty root has no verification campaign identity'
        end
      end
      capacity_assessment
      @state.private_directory(root, create: true)
      unless identity
        raise Error, 'nonempty root has no verification campaign identity' unless Dir.empty?(root)
        write('campaign.json', { 'schema' => 1, 'kind' => KIND, 'owner_uid' => Process.uid,
          'root' => File.realpath(root), 'campaign_id' => SecureRandom.uuid, 'inputs' => inputs }, immutable: true)
      end
      %w[temporary work output receipts].each { |name| @state.private_directory(file(name), create: true) }
      if File.exist?(file('config.json'))
        check(@state.file(file('config.json')) == @config_bytes, 'retained exact raw configuration')
      else
        File.open(file('config.json'), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |stream| stream.write(@config_bytes) }
      end
    end

    def run(phase)
      @phase = nil
      raise Error, 'unknown verification phase' unless PHASES.include?(phase)
      initialize_campaign
      lock = File.open(file('verify.lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
      @state.file(file('verify.lock'), limit: 0)
      named = File.lstat(file('verify.lock'))
      raise Error, 'campaign lock identity changed' unless [lock.stat.dev, lock.stat.ino] == [named.dev, named.ino]
      raise Error, 'verification campaign is already running' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      if phase == 'bilingual-capture'
        check_receipt('runtime-smoke')
      end
      if File.exist?(file("receipts/#{phase}.json"))
        check_receipt(phase)
        return if phase == 'installed-layout'
        raise Error, 'completed verification phase is immutable'
      end
      incomplete = PHASES.any? do |name|
        File.exist?(file("receipts/#{name}-attempt.json")) && !File.exist?(file("receipts/#{name}.json"))
      end
      raise Error, 'incomplete phase requires diagnosis; no automatic campaign replay' if incomplete
      @phase = phase
      checkpoint('started')
      public_send(phase.tr('-', '_'))
      write("receipts/#{phase}.json", { 'schema' => 1, 'kind' => KIND, 'phase' => phase, 'complete' => true,
        'inputs' => inputs, 'assertions' => assertions, 'finished_at' => Time.now.utc.iso8601 }, immutable: true)
    rescue StandardError => error
      checkpoint('failed', 'failed_stage' => @stage, 'error_class' => error.class.name) if @phase
      raise
    ensure
      lock&.close
    end

    def check_receipt(phase)
      receipt = read("receipts/#{phase}.json")
      check(receipt['schema'] == 1 && receipt['kind'] == KIND && receipt['phase'] == phase &&
        receipt['complete'] == true && receipt['inputs'] == inputs, "completed #{phase} same-input prerequisite")
    end

    def checkpoint(stage, detail = {})
      @stage = stage
      write("receipts/#{@phase}-attempt.json", { 'schema' => 1, 'kind' => KIND, 'phase' => @phase, 'complete' => false,
        'stage' => stage, 'inputs' => inputs, 'assertions' => assertions, 'time' => Time.now.utc.iso8601 }.merge(detail))
    end

    def command(*argv, cwd: file('work'), accepted: [0], input: '')
      output, _error, code = commands.call(argv, cwd:, accepted:, input:, stage: [@phase, @stage].compact.join('/'))
      [output, code]
    end

    def engine(action, *args, accepted: [0], input: '')
      capacity(action) if %w[start resume].include?(action)
      command(File.join(selection.fetch('runtime'), 'bin/vpsfree-kb-devcluster'), '--state-root', file('state'),
        action, 'same-slug', *args, accepted:, input:)
    end

    def installed_layout
      check(File.realpath(root) == root && !root.start_with?('/nix/store/'), 'ordinary private writable campaign root')
      _, repository_code = command('git', '-C', root, 'rev-parse', '--is-inside-work-tree', accepted: [0, 128])
      check(repository_code == 128, 'ordinary campaign is outside a Git checkout')
      before = source_hashes
      result, = engine('status')
      check(JSON.parse(result)['found'] == false, 'public status reports missing state')
      check(!File.exist?(file('state')) && !File.exist?(file('work/.devcluster')), 'status does not initialize state')
      command(File.join(selection.fetch('capture'), 'bin/vpsfree-kb-capture'), '--help')
      %w[work output].each do |directory|
        args = ['--connection', file('absent-connection'), '--language', 'en']
        args += ['--output-root', file('output')] if directory == 'output'
        _, code = command(File.join(selection.fetch('capture'), 'bin/vpsfree-kb-capture'), *args, accepted: [1])
        check(code == 1 && File.directory?(file("#{directory}/tmp")), 'packaged capture writable defaults and explicit output precede connection refusal')
      end
      check(source_hashes == before, 'installed layout leaves immutable source unchanged')
    end

    def source_hashes
      %w[captures.json flake.lock].to_h { |name| [name, Digest::SHA256.file(File.join(source.fetch('source'), name)).hexdigest] }
    end

    # These are separately assessed sequential peaks, not a sum of a builder
    # which has exited and guests which have not yet started.
    def memory_requirements(value, operation)
      guest_bytes = (config.fetch('services').fetch('memoryMiB') + config.fetch('nodes').fetch('node1').fetch('memoryMiB')) * 1024**2
      builder_bytes = config.fetch('services').fetch('memoryMiB') * 1024**2
      overhead = value.fetch('resource_overheads')
      phases = %w[construction runtime_browser].to_h do |name|
        assessed = overhead.fetch(name)
        ram = positive_bytes(assessed.fetch('ram_bytes'))
        shm = positive_bytes(assessed.fetch('shm_bytes'))
        raise Error, 'resource overhead requires an explicit assessment' unless assessed['assessment'].is_a?(String) && !assessed['assessment'].strip.empty?
        base = name == 'construction' ? builder_bytes : guest_bytes
        # Capture admits additional work after the existing live-guest continuity check.
        base = 0 if name == 'runtime_browser' && operation == 'capture'
        [name, { 'ram_bytes' => base + ram, 'shm_bytes' => base + shm }]
      end
      selected = operation == 'start' ? phases.values : [phases.fetch('runtime_browser')]
      { 'guest_bytes' => guest_bytes, 'builder_bytes' => builder_bytes, 'phase_requirements' => phases,
        'ram_bytes' => selected.map { |entry| entry['ram_bytes'] }.max,
        'shm_bytes' => selected.map { |entry| entry['shm_bytes'] }.max }
    end

    def capacity_assessment
      bytes = @state.file(@capacity_receipt)
      value = JSON.parse(bytes)
      raise Error, 'capacity receipt does not match campaign/source/packages/configuration' unless
        value['schema'] == 1 && value['kind'] == KIND && value['bindings'] == inputs
      observed = Time.iso8601(value.fetch('observed_at'))
      raise Error, 'capacity observation is in the future' if observed > Time.now
      plan = value.fetch('build_plan')
      unless plan['scratch_bound'] == 'unknown' && plan['assessment'].is_a?(String) && !plan['assessment'].strip.empty? &&
          plan['daemon_scratch_evidence'].is_a?(String) && !plan['daemon_scratch_evidence'].strip.empty? &&
          plan['max_jobs'] == 1 && plan['cores'] == 1 && plan['derivations'].is_a?(Array) &&
          plan['derivations'].all? { |entry| entry.is_a?(String) && !entry.empty? } &&
          plan['kernel_substitutions'].is_a?(Array) && !plan['kernel_substitutions'].empty? &&
          plan['kernel_substitutions'].all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
        raise Error, 'capacity receipt requires one job/core and explicit construction, kernel and unknown-scratch evidence'
      end
      memory_requirements(value, 'start')
      %w[allocated_bytes apparent_bytes].each { |name| nonnegative_bytes(value.fetch('owned_output').fetch(name)) }
      %w[realized_paths missing_paths filesystems].each { |name| raise Error, "capacity receipt lacks #{name}" unless value[name].is_a?(Array) }
      [value, Digest::SHA256.hexdigest(bytes)]
    rescue ArgumentError
      raise Error, 'invalid capacity observation time'
    end

    def nonnegative_bytes(value)
      raise Error, 'capacity byte count must be a nonnegative integer' unless value.is_a?(Integer) && value >= 0
      value
    end

    def positive_bytes(value)
      nonnegative_bytes(value)
      raise Error, 'assessed resource headroom must be positive' unless value.positive?
      value
    end

    def existing_ancestor(path)
      path = File.expand_path(path)
      @state.check_ancestors(path)
      path = File.dirname(path) until File.exist?(path)
      path
    end

    def filesystem(path)
      existing = existing_ancestor(path)
      target, = command('findmnt', '-n', '-o', 'TARGET', '-T', existing)
      type, = command('findmnt', '-n', '-o', 'FSTYPE', '-T', existing)
      available, = command('df', '-B1', '--output=avail', existing)
      { 'path' => File.expand_path(path), 'device' => File.stat(existing).dev,
        'mountpoint' => target.strip, 'fstype' => type.strip, 'available_bytes' => Integer(available.lines.last.strip) }
    end

    def host_capacity
      File.open('/dev/kvm', 'r+') { |device| raise Error, 'actual KVM API unavailable' unless device.ioctl(0xAE00) == 12 }
      ram = Integer(File.read('/proc/meminfo').match(/^MemAvailable:\s+(\d+)/)[1]) * 1024
      shm, = command('df', '-B1', '--output=avail', '/dev/shm')
      { 'ram_available' => ram, 'shm_available' => Integer(shm.lines.last.strip) }
    end

    def allocation(path)
      stat = File.lstat(path)
      raise Error, 'capacity path is not an ordinary file or directory' unless (stat.file? || stat.directory?) && !stat.symlink?
      if stat.file?
        allocated, apparent = stat.blocks * 512, stat.size
      else
        output, = command('du', '-s', '-B1', path)
        allocated = Integer(output.split.first)
        output, = command('du', '-s', '-B1', '--apparent-size', path)
        apparent = Integer(output.split.first)
      end
      { 'path' => path, 'device' => stat.dev, 'inode' => stat.ino, 'allocated_bytes' => allocated, 'apparent_bytes' => apparent }
    end

    def image_paths
      Dir.glob(file('state/clusters/same-slug/result-config-*')).filter_map do |path|
        @state.private_directory(File.dirname(path))
        resolved = File.realpath(path)
        raise Error, 'built configuration must remain an immutable store file' unless resolved.start_with?('/nix/store/') && File.file?(resolved)
        JSON.parse(File.read(resolved)).fetch('machines').fetch('services')['diskImage']
      end.uniq
    end

    def remaining_growth
      images = image_paths.map do |path|
        raise Error, 'service image must remain an immutable store path' unless path.start_with?('/nix/store/') && path == File.expand_path(path)
        allocation(path)
      end.uniq { |entry| [entry.fetch('device'), entry.fetch('inode')] }
      raise Error, 'single runtime campaign has more than one service image' if images.size > 1
      image_growth = [8 * GIB - images.sum { |entry| entry.fetch('allocated_bytes') }, 0].max
      disks = %w[services-root.img node1-tank.img].filter_map do |name|
        path = file("state/clusters/same-slug/disks/#{name}")
        File.exist?(path) ? allocation(path) : nil
      end.uniq { |entry| [entry.fetch('device'), entry.fetch('inode')] }
      disk_growth = 16 * GIB - disks.sum { |entry| [entry.fetch('allocated_bytes'), 8 * GIB].min }
      { 'image_bytes' => image_growth, 'disk_bytes' => disk_growth, 'realized_images' => images, 'retained_disks' => disks }
    end

    def capacity(operation)
      value, digest = capacity_assessment
      roles = value.fetch('roles')
      raise Error, 'capacity roles must name campaign, store and actual daemon scratch' unless roles.keys.sort == %w[builder_scratch state_images store]
      paths = { 'state_images' => root, 'store' => '/nix/store', 'builder_scratch' => roles.fetch('builder_scratch').fetch('path') }
      snapshots = paths.to_h do |role, path|
        expected = roles.fetch(role)
        raise Error, 'capacity filesystem path must be canonical and absolute' unless path == File.expand_path(path)
        actual = filesystem(path)
        raise Error, "capacity filesystem binding changed: #{role}" unless expected == actual.reject { |key, _| key == 'available_bytes' }
        [role, actual]
      end
      check(!%w[tmpfs ramfs].include?(snapshots.fetch('state_images').fetch('fstype')), 'campaign images use disk-backed filesystem')
      host = host_capacity
      demand = memory_requirements(value, operation)
      check(host.fetch('ram_available') >= demand.fetch('ram_bytes'), 'fresh host RAM covers the assessed phase peak')
      check(host.fetch('shm_available') >= demand.fetch('shm_bytes'), 'fresh shared memory covers the assessed phase peak')
      devices = snapshots.values.map { |entry| entry.fetch('device') }.uniq
      budgets = value.fetch('filesystems')
      unless budgets.map { |entry| entry.fetch('device') }.uniq.size == budgets.size && budgets.map { |entry| entry.fetch('device') }.sort == devices.sort
        raise Error, 'capacity assessment must budget each shared filesystem once'
      end
      growth = remaining_growth
      check(growth.fetch('realized_images').all? { |entry| entry['device'] == snapshots.fetch('store').fetch('device') }, 'service image remains on the bound store filesystem')
      check(growth.fetch('retained_disks').all? { |entry| entry['device'] == snapshots.fetch('state_images').fetch('device') }, 'retained disks remain on the bound campaign filesystem')
      charges = Hash.new(0)
      charges[snapshots.fetch('state_images').fetch('device')] += growth.fetch('disk_bytes')
      charges[snapshots.fetch('store').fetch('device')] += growth.fetch('image_bytes')
      realized = value.fetch('realized_paths').uniq.map do |path|
        raise Error, 'realized capacity path must be an immutable store path' unless path.start_with?('/nix/store/') && path == File.expand_path(path)
        allocation(path)
      end.uniq { |entry| [entry.fetch('device'), entry.fetch('inode')] }
      missing = value.fetch('missing_paths').group_by { |entry| entry.fetch('path') }.map do |path, entries|
        raise Error, 'conflicting repeated missing path evidence' unless entries.uniq.size == 1
        entry = entries.first
        raise Error, 'missing closure must be an immutable store path' unless path.start_with?('/nix/store/') && path == File.expand_path(path)
        raise Error, 'missing path kind must identify closure or budgeted service image' unless %w[closure service-image].include?(entry.fetch('kind'))
        nonnegative_bytes(entry.fetch('nar_size'))
        nonnegative_bytes(entry.fetch('download_size')) unless entry['download_size'].nil?
        charges[snapshots.fetch('store').fetch('device')] += entry.fetch('nar_size') if entry.fetch('kind') == 'closure' && !File.exist?(path)
        entry.merge('currently_realized' => File.exist?(path))
      end
      raise Error, 'receipt lists more than the one planned service image' if missing.count { |entry| entry['kind'] == 'service-image' } > 1
      fresh = budgets.map do |budget|
        device = budget.fetch('device')
        reserve = nonnegative_bytes(budget.fetch('reserve_bytes'))
        retained = nonnegative_bytes(budget.fetch('retained_growth_bytes'))
        headroom = positive_bytes(budget.fetch('build_headroom_bytes'))
        overlap = nonnegative_bytes(budget.fetch('construction_overlap_bytes'))
        unless budget['construction_overlap_assessment'].is_a?(String) && !budget['construction_overlap_assessment'].strip.empty?
          raise Error, 'construction staging/import overlap requires an explicit assessment'
        end
        overlap = 0 unless operation == 'start'
        raise Error, 'campaign base reserve must retain 16 GiB' if device == snapshots.fetch('state_images').fetch('device') && reserve < 16 * GIB
        nonnegative_bytes(budget.fetch('observed_available_bytes'))
        available = snapshots.values.select { |entry| entry['device'] == device }.map { |entry| entry.fetch('available_bytes') }.min
        remaining = charges.fetch(device, 0)
        check(available >= remaining + reserve + retained + headroom + overlap, 'fresh filesystem growth, retained reserve, assessed headroom and construction overlap')
        { 'device' => device, 'available_bytes' => available, 'remaining_growth_bytes' => remaining,
          'reserve_bytes' => reserve, 'retained_growth_bytes' => retained, 'construction_overlap_bytes' => overlap,
          'available_build_headroom_bytes' => available - remaining - reserve - retained - overlap,
          'assessed_build_headroom_bytes' => headroom }
      end
      write("receipts/capacity-#{SecureRandom.hex(12)}.json", { 'schema' => 1, 'kind' => KIND, 'operation' => operation,
        'receipt_sha256' => digest, 'assessment' => value, 'measured_at' => Time.now.utc.iso8601,
        'host' => host, 'memory_requirements' => demand, 'filesystems' => fresh, 'owned_output' => allocation(root),
        'realized_paths' => realized, 'remaining_growth' => growth, 'known_missing_paths' => missing,
        'scratch_bound' => 'unknown', 'intrinsic_output_envelope_bytes' => 24 * GIB }, immutable: true)
    end

    def descriptor
      out, = engine('connection')
      value = JSON.parse(out)
      check(value.dig('provenance', 'source') == source, 'exact final prepared source')
      check(value.fetch('machines').keys.sort == %w[node1 services], 'one services/node1 runtime')
      value.fetch('provenance').fetch('machine_toplevels').each do |machine, closure|
        identity, = engine('ssh', machine, '--', 'cat', '/etc/vpsfree-kb-capture.json')
        check(JSON.parse(identity) == value.fetch('provenance').fetch('guest_identity'), "#{machine} live guest identity")
        running, = engine('ssh', machine, '--', 'readlink', '-f', '/run/current-system')
        check(running.strip == closure, "#{machine} actual system closure")
      end
      value
    end

    def identities
      directory = file('state/clusters/same-slug')
      credentials = CREDENTIALS.to_h { |name| [name, Digest::SHA256.hexdigest(@state.file(File.join(directory, 'credentials', name)))] }
      disks = %w[services-root.img node1-tank.img].to_h do |name|
        path = File.join(directory, 'disks', name)
        stat = File.lstat(path)
        check(stat.file? && !stat.symlink? && stat.uid == Process.uid && stat.size == 8 * GIB, 'owned retained 8-GiB disk')
        [name, { 'device' => stat.dev, 'inode' => stat.ino, 'size' => stat.size }]
      end
      accounts = Digest::SHA256.hexdigest(@state.file(File.join(directory, 'accounts.json')))
      artifacts = Dir.glob(File.join(directory, 'artifact-*.json')).to_h { |path| [File.basename(path), Digest::SHA256.hexdigest(@state.file(path))] }
      images = image_paths.uniq.map do |path|
        stat = File.stat(path)
        check(stat.file? && stat.size == 8 * GIB, 'one fixed 8-GiB immutable image')
        { 'path' => path, 'device' => stat.dev, 'inode' => stat.ino, 'size' => stat.size }
      end.uniq { |entry| [entry['device'], entry['inode']] }
      check(images.size == 1 && artifacts.size == 1, 'one image and one accepted artifact')
      { 'credentials' => credentials, 'disks' => disks, 'accounts_sha256' => accounts, 'artifacts' => artifacts, 'images' => images }
    end

    def sentinels
      { 'services' => '/root/kb-root-sentinel', 'node1' => '/tank/kb-data-sentinel' }.to_h do |machine, path|
        output, = engine('ssh', machine, '--', 'sha256sum', path)
        [machine, output.split.first]
      end
    end

    def continuity(previous, current, identity, sentinel)
      check(current.fetch('instance_id') == previous.fetch('instance_id'), 'retained instance identity')
      check(current.fetch('run_id') != previous.fetch('run_id'), 'fresh live run identity')
      check(current.fetch('artifact_id') == previous.fetch('artifact_id') && current.fetch('artifact_sha256') == previous.fetch('artifact_sha256'), 'cold resume reuses accepted artifact')
      check(current.fetch('provenance').fetch('machine_toplevels') == previous.fetch('provenance').fetch('machine_toplevels'), 'cold resume does not rebuild closures')
      check(identities == identity, 'six credentials, accounts, disks, artifact and image identities preserved')
      check(sentinels == sentinel, 'root/data sentinels preserved')
    end

    def read_smoke(connection_path)
      script = <<~'JS'
        const fs = require('node:fs');
        const path = require('node:path');
        const { Connection, openLease, readConnection } = require(path.join(process.argv[3], 'lib/connection.cjs'));
        const { launchBrowser, login } = require(path.join(process.argv[3], 'lib/browser.cjs'));
        const { goto } = require(path.join(process.argv[3], 'lib/webui.cjs'));
        const { inventoryIdentity, assertInventoryMember } = require(path.join(process.argv[3], 'fixtures/prepare.cjs'));
        async function main() {
          const { value, digest } = readConnection(process.argv[1], ['ip-inventory']);
          const source = JSON.parse(fs.readFileSync(process.argv[2]));
          const expected = { schema: 1, instance_id: value.instance_id, run_id: value.run_id,
            artifact_id: value.artifact_id, artifact_sha256: value.artifact_sha256, descriptor_sha256: digest };
          const argv = [...value.control.argv, '--instance-id', value.instance_id, '--run-id', value.run_id,
            '--artifact-id', value.artifact_id, '--artifact-sha256', value.artifact_sha256, '--descriptor-sha256', digest];
          const lease = await openLease(argv, expected);
          let browser;
          try {
            const connection = new Connection(value, lease);
            await connection.verify(source);
            const { member } = await inventoryIdentity(connection);
            browser = await launchBrowser(connection, { width: 1280, height: 800 }, 'en');
            const page = await browser.context.newPage();
            await login(page, connection, 'en');
            await goto(page, '/?page=adminvps&action=list');
            await assertInventoryMember(page, member);
            lease.assertLive();
            process.stdout.write(JSON.stringify({ member, api_tls_verified: true, php_member_read: true,
              page: '/?page=adminvps&action=list', instance_id: value.instance_id, run_id: value.run_id }) + '\n');
          } finally {
            try { if (browser) await browser.close(); } finally { await lease.close(); }
          }
        }
        main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
      JS
      output, = command('node', '-e', script, connection_path, selection.fetch('metadata'), source.fetch('source'))
      value = JSON.parse(output)
      check(value['api_tls_verified'] == true && value['php_member_read'] == true && value.dig('member', 'login') == 'test-user1', 'real TLS/API identity and ordinary member PHP read')
      write('receipts/read-smoke.json', value, immutable: true)
    end

    def resources(value, capture: false)
      observations = {}
      %w[services node1].each do |machine|
        script = <<~SH
          set -eu
          printf 'available_memory_bytes=%s\n' "$(awk '/^MemAvailable:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)"
          if test -r /proc/pressure/memory; then cat /proc/pressure/memory; fi
        SH
        if machine == 'services'
          script += "printf 'available_bytes=%s\\n' \"$(df -B1 --output=avail / | tail -n 1 | tr -d ' ')\"\n"
          script += "printf 'available_inodes=%s\\n' \"$(df -i --output=iavail / | tail -n 1 | tr -d ' ')\"\n"
        else
          script += "printf 'tank_available_bytes=%s\\n' \"$(zfs get -Hp -o value available tank)\"\n"
        end
        output, = engine('ssh', machine, '--', 'sh', '-s', input: script)
        numeric = output.lines.filter_map do |line|
          match = /\A([a-z_]+)=([0-9]+)\n?\z/.match(line)
          [match[1], Integer(match[2])] if match
        end.to_h
        required = machine == 'services' ? %w[available_memory_bytes available_bytes available_inodes] : %w[available_memory_bytes tank_available_bytes]
        check(numeric.keys.sort == required.sort, "#{machine} real resource observations")
        observations[machine] = numeric.merge('pressure' => output.lines.reject { |line| /\A[a-z_]+=[0-9]+\n?\z/.match?(line) }.join)
      end
      check(observations.fetch('services').fetch('available_bytes') >= GIB, '1 GiB services writable headroom before fixtures')
      if capture
        assessment = capacity_assessment.first.fetch('capture_assessment')
        check(assessment['assessment'].is_a?(String) && !assessment['assessment'].strip.empty?, 'explicit template/quota/memory assessment')
        services = observations.fetch('services')
        node = observations.fetch('node1')
        check(services.fetch('available_inodes') >= positive_bytes(assessment.fetch('minimum_free_inodes')), 'assessed services inode headroom')
        check(services.fetch('available_memory_bytes') >= positive_bytes(assessment.fetch('services_memory_bytes')) &&
          node.fetch('available_memory_bytes') >= positive_bytes(assessment.fetch('node_memory_bytes')), 'assessed live guest memory headroom')
        check(node.fetch('tank_available_bytes') >= 4 * GIB + positive_bytes(assessment.fetch('template_metadata_bytes')), 'real 4-GiB quota plus assessed template/metadata headroom')
      end
      write("receipts/resources-#{value.fetch('run_id')}-#{SecureRandom.hex(6)}.json", { 'schema' => 1, 'kind' => KIND,
        'run_id' => value.fetch('run_id'), 'artifact_id' => value.fetch('artifact_id'), 'source' => source,
        'capture_admitted' => capture, 'observations' => observations, 'output_allocations' => remaining_growth }, immutable: true)
    end

    def runtime_smoke
      checkpoint('starting-final-runtime')
      engine('start', '--timeout', '900', '--network', 'local', '--topology', 'single', '--config', file('config.json'))
      first = descriptor
      write('smoke-connection.json', first, immutable: true)
      resources(first)
      checkpoint('member-read-smoke')
      read_smoke(file('smoke-connection.json'))
      checkpoint('public-lease-proof')
      command('node', File.join(source.fetch('source'), 'tools/verify-live-lease.cjs'), file('smoke-connection.json'),
        selection.fetch('metadata'), selection.fetch('runtime'), file('state'), file('config.json'))
      assertions << 'public lease lifecycle exclusion, EOF/interruption, reacquisition, wrong-source refusal and routing'
      checkpoint('continuity-baseline')
      { 'services' => '/root/kb-root-sentinel', 'node1' => '/tank/kb-data-sentinel' }.each do |machine, path|
        engine('ssh', machine, '--', 'sh', '-c', 'set -e; test ! -e "$1"; printf "%s" "$2" > "$1"', 'sh', path, read('campaign.json').fetch('campaign_id'))
      end
      identity, sentinel = identities, sentinels
      write('continuity.json', { 'identities' => identity, 'sentinels' => sentinel }, immutable: true)
      checkpoint('ordinary-public-stop')
      engine('stop', '--timeout', '900')
      result, = engine('status')
      stopped = JSON.parse(result)
      check(stopped['found'] == true && stopped['state'] == 'stopped' && stopped['ready'] == false, 'ordinary public stop completed')
      proof = read("state/clusters/same-slug/processes-#{first.fetch('run_id')}.json")
      check(proof['schema'] == 1 && proof['complete'] == true &&
        %w[instance_id run_id artifact_id artifact_sha256].all? { |key| proof[key] == first.fetch(key) }, 'retained complete exit receipt')
      checkpoint('same-artifact-public-resume')
      engine('resume', '--timeout', '900')
      resumed = descriptor
      continuity(first, resumed, identity, sentinel)
      resources(resumed)
      write('accepted-runtime.json', resumed, immutable: true)
      assertions << 'one final-source start/stop/resume; no historical upgrade or two-cluster claim'
    end

    def bilingual_capture
      current = descriptor
      check(current == read('accepted-runtime.json'), 'capture uses the same completed resumed runtime')
      baseline = read('continuity.json')
      check(identities == baseline.fetch('identities') && sentinels == baseline.fetch('sentinels'), 'capture retains smoke continuity')
      checkpoint('capture-resource-admission')
      capacity('capture')
      resources(current, capture: true)
      before = source_hashes
      output = file('output')
      capture = File.join(selection.fetch('capture'), 'bin/vpsfree-kb-capture')
      checkpoint('bilingual-ip-inventory')
      command(capture, '--cluster', 'same-slug', '--state-root', file('state'), '--language', 'cs', '--checkpoint', 'networking/ip-address-list', '--output-root', output)
      value, = engine('connection')
      write('capture-connection.json', JSON.parse(value))
      command(capture, '--connection', file('capture-connection.json'), '--language', 'en', '--checkpoint', 'networking/ip-address-list', '--output-root', output)
      command(capture, '--connection', file('capture-connection.json'), '--language', 'en', '--checkpoint', 'networking/ip-address-list', cwd: output)
      validate = File.join(selection.fetch('capture'), 'bin/vpsfree-kb-validate')
      checkpoint('strict-validation-export')
      command(validate, '--update', '--output-root', output)
      command(validate, '--output-root', output)
      rows = JSON.parse(File.read(File.join(output, 'tmp/capture-results.json')))
      check(rows.map { |row| [row.fetch('language'), row.fetch('id')] }.sort == [['cs', 'networking/ip-address-list'], ['en', 'networking/ip-address-list']], 'exact bilingual results')
      check(rows.all? { |row| row.dig('provenance', 'source') == source }, 'both captures bind final immutable source')
      check(source_hashes == before, 'capture/validation leave source immutable')
      write('receipts/export.json', KbCaptureArtifacts.export(output, file('export')), immutable: true)
      assertions << 'strict installed full-inventory validation and five-file physical-lock checksum export'
    end
  end

  def self.run(argv)
    options = {}
    parser = OptionParser.new do |value|
      value.banner = 'Usage: vpsfree-kb-verify --root DIR --config FILE --capacity-receipt FILE --phase PHASE'
      %w[root config capacity-receipt phase selection].each do |name|
        value.on("--#{name} VALUE") do |argument|
          key = name.tr('-', '_').to_sym
          raise Error, "duplicate option: --#{name}" if options.key?(key)
          options[key] = argument
        end
      end
      value.on('--help') { puts value; return 0 }
    end
    parser.parse!(argv)
    raise Error, 'unexpected positional arguments' unless argv.empty?
    phase = options.delete(:phase) || raise(Error, '--phase is required')
    selected = options.delete(:selection) || raise(Error, 'use the packaged verifier with its fixed source selection')
    %i[root config capacity_receipt].each { |name| options.fetch(name) }
    options[:selection] = JSON.parse(File.read(selected))
    Campaign.new(**options).run(phase)
    puts JSON.generate('phase' => phase, 'complete' => true)
    0
  rescue Error, KbRuntime::Error, KeyError, OptionParser::ParseError, JSON::ParserError, SystemCallError => error
    warn "Verification refused: #{error.message}"
    1
  end
end

exit KbVerify.run(ARGV) if $PROGRAM_NAME == __FILE__
