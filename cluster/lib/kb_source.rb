# frozen_string_literal: true

require 'open3'
require_relative 'kb_state'

module KbRuntime
  class Software
    attr_reader :metadata, :source

    def initialize(metadata)
      raise Error, 'unsupported immutable source metadata' unless metadata['schema'] == 1
      @metadata = metadata
      @source = metadata.fetch('source')
      raise Error, 'capture requires a committed K revision' unless /\A[0-9a-f]{40}\z/.match?(metadata.fetch('revision'))
      raise Error, 'immutable K source is required' unless source.start_with?('/nix/store/') && File.directory?(source)
      raise Error, 'K lock digest differs' unless Digest::SHA256.file(File.join(source, 'flake.lock')).hexdigest == metadata.fetch('lock_sha256')
      lock = JSON.parse(File.read(File.join(source, 'flake.lock')))
      raise Error, 'K input identities differ' unless metadata.fetch('inputs') == self.class.locked_inputs(lock)
      raise Error, 'fixture contract differs' unless metadata.fetch('fixture_sha256') == self.class.fixture_digest(source)
    end

    def self.command(*argv, env: {})
      out, _err, status = Open3.capture3(env, *argv)
      raise Error, "command failed: #{argv.first}" unless status.success?

      out.strip
    end

    def self.fixture_digest(root)
      names = %w[fixtures/production-shape.json fixtures/prepare.cjs]
      Digest::SHA256.hexdigest(names.map { |name| "#{name}\0#{Digest::SHA256.file(File.join(root, name)).hexdigest}" }.join("\n"))
    end

    def self.locked_inputs(lock)
      values = {}
      visit = lambda do |node, prefix, ancestors|
        raise Error, 'cyclic flake input graph' if ancestors.include?(node)
        lock.fetch('nodes').fetch(node).fetch('inputs', {}).sort.each do |name, reference|
          reference = resolve_follows(lock, reference) if reference.is_a?(Array)
          path = [prefix, name].compact.join('/')
          locked = lock.fetch('nodes').fetch(reference).fetch('locked')
          values[path] = locked.slice('rev', 'narHash')
          visit.call(reference, path, ancestors + [node])
        end
      end
      visit.call('root', nil, [])
      values
    end

    def self.resolve_follows(lock, parts, seen = [])
      raise Error, 'cyclic flake follows' if seen.include?(parts)
      node = 'root'
      parts.each_with_index do |part, index|
        reference = lock.fetch('nodes').fetch(node).fetch('inputs').fetch(part)
        if reference.is_a?(Array)
          return resolve_follows(lock, reference + parts.drop(index + 1), seen + [parts])
        end
        node = reference
      end
      node
    end

    def self.checkout(root)
      raise Error, 'commit K runtime changes before creating capture evidence' unless command('git', '-C', root, 'status', '--porcelain').empty?
      revision = command('git', '-C', root, 'rev-parse', 'HEAD')
      ref = "git+file://#{root}?rev=#{revision}"
      immutable = command('nix', 'eval', '--raw', '--impure', '--expr', "(builtins.getFlake #{ref.to_json}).outPath")
      lock = JSON.parse(File.read(File.join(immutable, 'flake.lock')))
      new('schema' => 1, 'revision' => revision, 'source' => immutable,
          'lock_sha256' => Digest::SHA256.file(File.join(immutable, 'flake.lock')).hexdigest,
          'fixture_sha256' => fixture_digest(immutable), 'inputs' => locked_inputs(lock))
    end

    def prepare(state, identity, config, topology:, network:, credentials:)
      artifact_id = SecureRandom.uuid
      directory = state.path("artifact-#{artifact_id}")
      state.private_directory(directory, create: true)
      config_path = File.join(directory, 'input.json')
      state.write(config_path, config, immutable: true)
      inputs = { 'config' => config, 'topology' => topology, 'network' => network,
                 'bridge_helper' => '/run/wrappers/bin/qemu-bridge-helper' }
      input_digest = Digest::SHA256.hexdigest(self.class.canonical_json(inputs))
      guest = { 'schema' => 1, 'instance_id' => identity.fetch('instance_id'), 'artifact_id' => artifact_id,
                'config_input_sha256' => input_digest, 'source' => metadata }
      guest_path = File.join(directory, 'guest.json')
      state.write(guest_path, guest, immutable: true)
      requested = identity.merge('artifact_id' => artifact_id, 'topology' => topology, 'network' => network)
      env = self.class.build_environment(state, requested, config_path, credentials, guest_path)
      plan = JSON.parse(self.class.command('nix', 'eval', '--no-write-lock-file', '--impure', '--json',
                          "path:#{source}#runtimePlan", env:))
      layout = self.class.layout(plan)
      { 'schema' => 1, 'instance_id' => identity.fetch('instance_id'), 'artifact_id' => artifact_id,
        'source' => metadata, 'topology' => topology, 'network' => network,
        'input_path' => config_path, 'config_input_sha256' => input_digest, 'build_inputs' => inputs,
        'guest_path' => guest_path, 'guest_identity' => guest, 'layout' => layout,
        'credential_identity' => self.class.credentials_identity(credentials) }
    end

    def self.canonical_json(value)
      value = value.sort.to_h.transform_values { |entry| JSON.parse(canonical_json(entry)) } if value.is_a?(Hash)
      value = value.map { |entry| JSON.parse(canonical_json(entry)) } if value.is_a?(Array)
      JSON.generate(value)
    end

    def self.credentials_identity(directory)
      %w[id_ed25519 id_ed25519.pub vpsadmin-ca.crt vpsadmin-ca.key vpsadmin-cert.crt vpsadmin-cert.key].to_h do |name|
        [name, Digest::SHA256.file(File.join(directory, name)).hexdigest]
      end
    end

    def self.layout(config)
      config.fetch('machines').transform_values do |machine|
        raise Error, 'portable artifacts require direct boot' unless machine.fetch('bootMode', 'direct') == 'direct'
        raise Error, 'unsupported machine spin' unless %w[nixos vpsadminos].include?(machine.fetch('spin'))
        disks = machine.fetch('disks', []).map do |disk|
          unless disk.fetch('type', 'file') == 'file' && disk.fetch('create', true) == true &&
                 /\A[a-zA-Z0-9_.-]+\z/.match?(disk.fetch('device')) && !%w[. .. root].include?(disk['device']) &&
                 (!disk.key?('path') || /\A[a-zA-Z0-9_.-]+\z/.match?(disk['path']))
            raise Error, 'portable artifacts require owned relative file disks'
          end
          disk.slice('device', 'type', 'size', 'sizeMiB', 'path').merge('create' => true)
        end
        raise Error, 'duplicate declared disk device' unless disks.map { |disk| disk['device'] }.uniq.size == disks.size
        { 'spin' => machine.fetch('spin'), 'boot_mode' => 'direct',
          'root_image' => !machine['diskImage'].nil?, 'disks' => disks }
      end
    end

    def build(state, candidate, credentials)
      env = self.class.build_environment(state, candidate, candidate.fetch('input_path'), credentials, candidate.fetch('guest_path'))
      result = state.path("result-config-#{candidate.fetch('artifact_id')}")
      self.class.command('nix', 'build', '--no-write-lock-file', '--impure', '--out-link', result,
                         "path:#{source}#cluster-config", env:)
      config_path = File.realpath(result)
      config = JSON.parse(File.read(config_path))
      runner_root = state.path("result-runner-#{candidate.fetch('artifact_id')}")
      self.class.command('nix', 'build', '--no-write-lock-file', '--out-link', runner_root,
                          "path:#{source}#runner", env:)
      runner = File.realpath(runner_root)
      raise Error, 'built machine layout differs from preflight' unless self.class.layout(config) == candidate.fetch('layout')
      candidate.merge('build_inputs' => candidate.fetch('build_inputs').reject { |key, _value| key == 'config' },
                   'config_path' => config_path, 'config_sha256' => Digest::SHA256.file(config_path).hexdigest,
                   'runner' => File.join(runner, 'bin/vpsadmin-kb-capture-cluster-runner'),
                   'runner_identity' => JSON.parse(self.class.command('nix', 'eval', '--json', "path:#{source}#runtimeRunner", env:)),
                   'machine_toplevels' => config.fetch('machines').transform_values { |machine| machine.fetch('toplevel') },
                   'machine_boot' => config.fetch('machines').transform_values { |machine| machine.slice('kernel', 'initrd', 'toplevel', 'squashfs', 'diskImage') },
                   'result_roots' => [result, runner_root])
    end

    def self.build_environment(state, launch, config_file, credentials, guest_path)
      # Open3 overlays ENV. Explicit nil entries remove inherited dev-shell source
      # overrides, including any future override under these owning prefixes.
      cleared = ENV.keys.grep(/\AVPSADMIN_(?:DEVCLUSTER|KB)_/).to_h { |name| [name, nil] }
      cleared.merge('VPSADMIN_DEVCLUSTER_SLUG' => state.slug,
              'VPSADMIN_DEVCLUSTER_TOPOLOGY' => launch.fetch('topology'),
              'VPSADMIN_DEVCLUSTER_NETWORK' => launch.fetch('network'),
              'VPSADMIN_DEVCLUSTER_CONFIG_FILE' => config_file,
              'VPSADMIN_DEVCLUSTER_CERT_DIR' => credentials,
              'VPSADMIN_DEVCLUSTER_SSH_PUBKEY' => File.join(credentials, 'id_ed25519.pub'),
              'VPSADMIN_DEVCLUSTER_BRIDGE_HELPER' => launch.fetch('bridge_helper', '/run/wrappers/bin/qemu-bridge-helper'),
              'VPSADMIN_DEVCLUSTER_TELEGRAM_ENABLE' => '0',
              'VPSADMIN_KB_INSTANCE_ID' => launch.fetch('instance_id'),
              'VPSADMIN_KB_CAPTURE_IDENTITY_FILE' => guest_path)
    end
  end
end
