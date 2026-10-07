# frozen_string_literal: true

require 'shellwords'
require_relative 'kb_source'

module KbRuntime
  # Imports exact prepared closures through the attested predecessor. This does
  # not activate them or change the predecessor's running source identity.
  class ClosurePreparation
    RESERVE_BYTES = 256 * 1024 * 1024
    RESERVE_INODES = 10_000

    def initialize(engine)
      @engine = engine
    end

    def host_info(toplevel)
      result = normalize(JSON.parse(Software.command('nix', 'path-info', '--recursive', '--json', toplevel,
                                                     env: copy_environment)))
      result.each_key { |path| Software.command('nix-store', '--verify-path', path, env: copy_environment) }
      result
    end

    def normalize(value)
      value = value.to_h { |entry| [entry.fetch('path'), entry] } if value.is_a?(Array)
      value.sort.to_h.transform_values do |entry|
        { 'narHash' => entry.fetch('narHash'), 'narSize' => entry.fetch('narSize'),
          'references' => entry.fetch('references').sort }
      end
    end

    def copy_environment
      names = ENV.keys.grep(/\A(?:VPSADMIN_(?:DEVCLUSTER|KB)_|NIX_|SSH_)/)
      names.to_h { |name| [name, nil] }
    end

    def ssh_options(record, machine)
      endpoint = record.fetch('endpoints').fetch(machine)
      credentials = @engine.state.path('credentials')
      ['-F', File::NULL, '-i', File.join(credentials, 'id_ed25519'), '-p', endpoint.fetch('port').to_s,
       '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
       '-o', "UserKnownHostsFile=#{File.join(credentials, 'known_hosts')}",
       '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=5']
    end

    def prepare(old, artifact)
      state = @engine.state
      artifact.fetch('layout').each do |machine, layout|
        next unless layout.fetch('spin') == 'nixos'

        @engine.verify_live(old)
        toplevel = artifact.fetch('machine_toplevels').fetch(machine)
        expected = host_info(toplevel)
        check_tools(old, machine)
        missing = expected.keys.reject do |path|
          @engine.ssh(old, machine, 'sh', '-c', 'nix-store --check-validity "$1" >/dev/null 2>&1 && printf valid || true', 'sh', path) == 'valid'
        end
        capacity(old, machine, missing.sum { |path| expected.fetch(path).fetch('narSize') }, inode_count(missing))
        endpoint = old.fetch('endpoints').fetch(machine)
        host = endpoint.fetch('host')
        host = "[#{host}]" if host.include?(':')
        environment = copy_environment.merge('NIX_SSHOPTS' => Shellwords.join(ssh_options(old, machine)))
        Software.command('nix', 'copy', '--to', "ssh://root@#{host}", toplevel, env: environment)
        verify_closure(old, machine, toplevel, expected)
        root = "/nix/var/nix/gcroots/vpsfree-kb/#{old.fetch('instance_id')}/#{artifact.fetch('artifact_id')}/#{machine}"
        @engine.ssh(old, machine, 'sh', '-s', '--', root, toplevel, input: <<~SH)
          set -eu
          mkdir -p "$(dirname "$1")"
          if test -e "$1" || test -L "$1"; then
            test -L "$1" && test "$(readlink "$1")" = "$2"
          else
            ln -s "$2" "$1"
          fi
          test "$(readlink -f "$1")" = "$2"
        SH
        verify_closure(old, machine, toplevel, expected)
        @engine.verify_live(old)
        state.write(state.path("prepared-#{artifact.fetch('artifact_id')}-#{machine}.json"),
          { 'schema' => 1, 'instance_id' => old['instance_id'], 'old_run_id' => old['run_id'],
          'artifact_id' => artifact['artifact_id'], 'artifact_sha256' => @engine.artifact_digest(artifact), 'machine' => machine, 'complete' => true,
          'toplevel' => toplevel, 'closure' => expected, 'guest_root' => root })
      end
      state.write(state.path("prepared-#{artifact.fetch('artifact_id')}.json"),
        { 'schema' => 1, 'instance_id' => old['instance_id'], 'artifact_id' => artifact['artifact_id'],
        'layout' => artifact.fetch('layout'), 'complete' => true, 'kind' => 'import' })
    end

    def check_tools(old, machine)
      @engine.ssh(old, machine, 'sh', '-c',
        'set -eu; command -v nix; command -v nix-store; test -w /nix/store; test -w /nix/var/nix/db; nix --version >/dev/null')
    end

    # Count the exact local closure entries without following symlinks. Counting
    # hardlinks separately deliberately overestimates the guest inode need.
    def inode_count(paths)
      count = 0
      pending = paths.dup
      until pending.empty?
        path = pending.pop
        stat = File.lstat(path)
        count += 1
        pending.concat(Dir.children(path).map { |name| File.join(path, name) }) if stat.directory?
      end
      count
    end

    def capacity(old, machine, bytes, inodes)
      output = @engine.ssh(old, machine, 'sh', '-c',
        'set -eu; df -B1 --output=avail /nix/store | tail -n1; df -i --output=iavail /nix/store | tail -n1')
      free_bytes, free_inodes = output.split.map { |value| Integer(value) }
      unless free_bytes && free_inodes && free_bytes >= bytes + RESERVE_BYTES && free_inodes >= inodes + RESERVE_INODES
        raise Error, "insufficient guest store space on #{machine}; no GC or resize was attempted"
      end
    end

    def verify_closure(old, machine, toplevel, expected)
      remote = normalize(JSON.parse(@engine.ssh(old, machine, 'nix', 'path-info', '--recursive', '--json', toplevel)))
      raise Error, "imported closure identity differs on #{machine}" unless remote == expected
      expected.each_key { |path| @engine.ssh(old, machine, 'nix-store', '--verify-path', path) }
    end
  end
end
