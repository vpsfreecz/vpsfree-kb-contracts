# frozen_string_literal: true

require 'ipaddr'
require 'socket'
require 'open3'
require_relative 'kb_state'

module KbRuntime
  class Resources
    attr_reader :state, :root

    def initialize(state, root: nil)
      @state = state
      @root = root || File.join(runtime_root(state), 'reservations')
    end

    def runtime_root(state)
      candidate = ENV['XDG_RUNTIME_DIR']
      if candidate && state.private_directory(candidate)
        base = File.join(candidate, 'vpsfree-kb')
      else
        base = "/tmp/vpsfree-kb-#{Process.uid}"
      end
      state.private_directory(base) if File.exist?(base) || File.symlink?(base)
      base
    end

    def socket_dir(instance_id, run_id)
      base = File.dirname(root)
      name = Digest::SHA256.hexdigest([state.root, instance_id, run_id].join("\0"))[0, 20]
      path = File.join(base, "run-#{name}")
      raise Error, 'runtime socket path is too long' if "#{path}/control.sock".bytesize > 100

      path
    end

    def synchronize
      state.private_directory(root, create: true)
      path = File.join(root, 'lock')
      unless File.exist?(path) || File.symlink?(path)
        begin
          File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) {}
        rescue Errno::EEXIST
          # Validate the existing lock below.
        end
      end
      state.file(path, limit: 0)
      File.open(path, File::RDWR | File::NOFOLLOW) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def conflicting?(left, right)
      return left['port'] == right['port'] if left['kind'] == 'udp' && right['kind'] == 'udp'
      return left == right unless left['kind'] == 'tcp' && right['kind'] == 'tcp'
      return false unless left['port'] == right['port']

      left['host'] == right['host'] || %w[0.0.0.0 ::].include?(left['host']) || %w[0.0.0.0 ::].include?(right['host'])
    end

    def claim(launch)
      claims = launch.fetch('resource_claims').sort_by { |claim| JSON.generate(claim) }
      raise Error, 'duplicate requested host resource' unless claims.uniq == claims
      synchronize do
        Dir.glob(File.join(root, '*.json')).sort.each do |path|
          record = state.read(path)
          next if record['instance_id'] == launch['instance_id'] && record['run_id'] == launch['run_id'] && record['resource_claims'] == claims
          if record.fetch('resource_claims').any? { |other| claims.any? { |wanted| conflicting?(wanted, other) } }
            raise Error, 'requested resource is already claimed; no automatic release or fallback'
          end
        end
        probes = []
        begin
          claims.select { |claim| claim['kind'] == 'tcp' }.each do |claim|
            probes << TCPServer.new(claim.fetch('host'), claim.fetch('port'))
          end
          claims.select { |claim| claim['kind'] == 'udp' }.each do |claim|
            probe = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
            probes << probe
            probe.bind(Socket.sockaddr_in(claim.fetch('port'), claim.fetch('host')))
          end
          claims.select { |claim| claim['kind'] == 'bridge-address' }.each do |claim|
            _out, _err, status = Open3.capture3('ping', '-c', '1', '-W', '1', claim.fetch('address'))
            raise Error, 'requested bridge address responds; ownership is not established' if status.success?
          end
          path = File.join(root, "#{launch.fetch('instance_id')}-#{launch.fetch('run_id')}.json")
          expected = launch.slice('instance_id', 'run_id', 'artifact_id', 'artifact_sha256', 'boot_id', 'owner_uid', 'state_root', 'slug', 'resource_claims')
          if File.exist?(path)
            raise Error, 'different retained resource claim' unless state.read(path) == expected
          else
            state.write(path, expected, immutable: true)
          end
        ensure
          probes.each(&:close)
        end
      end
    rescue Errno::EADDRINUSE, Errno::EACCES, Errno::EADDRNOTAVAIL
      raise Error, 'requested bind address/port is unavailable; no automatic fallback'
    end

    def release(launch, processes_gone:)
      raise Error, 'process exit proof is required before releasing resources' unless processes_gone

      synchronize do
        path = File.join(root, "#{launch.fetch('instance_id')}-#{launch.fetch('run_id')}.json")
        return unless File.exist?(path)

        expected = launch.slice('instance_id', 'run_id', 'artifact_id', 'artifact_sha256', 'boot_id', 'owner_uid', 'state_root', 'slug', 'resource_claims')
        raise Error, 'foreign resource reservation' unless state.read(path) == expected

        File.unlink(path)
      end
    end
  end
end
