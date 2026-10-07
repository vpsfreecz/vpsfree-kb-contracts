# frozen_string_literal: true

require 'osvm'
require 'socket'
require_relative 'kb_disks'

module KbRuntime
  # Keep OSVM's daemon/reaper ownership, but supply the listener ourselves so
  # virtiofsd never creates a companion pidfile in the private namespace.
  module VirtiofsListeners
    def initialize(...)
      super
      @kb_virtiofs_paths = {}
      @kb_virtiofs_mutex = Mutex.new
    end

    def cleanup
      @kb_virtiofs_mutex.synchronize do
        Thread.handle_interrupt(Exception => :never) do
          begin
            # Do not call Machine#cleanup: its unchecked socket unlink would
            # discard the identity proof this adapter retains.
            @kb_virtiofs_paths.each_value { |proof| check_virtiofs_path(proof) }
            shell_instances.each(&:cleanup)
            @kb_virtiofs_paths.each_value do |proof|
              File.unlink(proof.fetch(:path)) if check_virtiofs_path(proof)
              proof[:absent] = true
            end
          ensure
            @kb_virtiofs_paths.each_value do |proof|
              proof[:refused] = true unless proof[:absent]
              close_virtiofs_proof(proof)
            end
          end
        end
      end
      self
    end

    protected

    def start_virtiofs
      @kb_virtiofs_mutex.synchronize do
        shared_filesystems.each do |share, shared_path|
          Thread.handle_interrupt(Exception => :never) do
            listener = output = proof = nil
            begin
              path = virtiofs_socket_path(share)
              raise Error, 'virtiofs listener already retained' if @kb_virtiofs_paths[path] && !@kb_virtiofs_paths[path][:absent]
              directory = File.dirname(path)
              proof = { path:, directory:, absent: false }
              proof[:directory_fd] = File.open(directory, File::RDONLY | File::NOFOLLOW | 0x10000 | 0x80000) # O_DIRECTORY | O_CLOEXEC
              proof[:directory_fd].close_on_exec = true
              proof[:directory_identity] = virtiofs_identity(proof[:directory_fd].stat, 'directory', 0o700)
              check_virtiofs_directory(proof)
              [path, path + '.pid'].each do |candidate|
                begin
                  File.lstat(candidate)
                rescue Errno::ENOENT
                  next
                end
                raise Error, 'virtiofs listener path or pidfile already exists'
              end
              listener = Socket.new(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
              listener.close_on_exec = true
              listener.bind(Socket.sockaddr_un(path))
              # O_PATH retains the filesystem inode, unlike the listener FD.
              named = File.lstat(path)
              proof[:socket_fd] = File.open(path, 0x200000 | File::NOFOLLOW | 0x80000) # O_PATH | O_CLOEXEC
              proof[:socket_fd].close_on_exec = true
              opened = proof[:socket_fd].stat
              unless named.socket? && opened.socket? && named.uid == Process.uid && opened.uid == Process.uid && [named.dev, named.ino] == [opened.dev, opened.ino]
                raise Error, 'virtiofs listener changed during acquisition'
              end
              @kb_virtiofs_paths[path] = proof
              File.chmod(0o600, path)
              proof[:socket_identity] = virtiofs_identity(proof[:socket_fd].stat, 'socket', 0o600)
              check_virtiofs_path(proof)
              listener.listen(Socket::SOMAXCONN)
              output = File.open(virtiofs_log_path(share), 'w')
              virtiofsd_pids << Process.spawn(
                File.join(config.virtiofsd, 'bin/virtiofsd'),
                '--fd', '3', '--shared-dir', shared_path, '--cache', 'auto',
                3 => listener, in: :close, out: output, err: output, close_others: true
              )
            ensure
              begin
                listener&.close unless listener&.closed?
              ensure
                begin
                  output&.close unless output&.closed?
                ensure
                  close_virtiofs_proof(proof) if proof && !@kb_virtiofs_paths.value?(proof)
                end
              end
            end
          end
        end
      end
    end

    def virtiofs_identity(stat, type, mode)
      unless stat.ftype == type && stat.uid == Process.uid && (stat.mode & 0o7777) == mode
        raise Error, 'unsafe virtiofs listener metadata'
      end
      [stat.dev, stat.ino, stat.ftype, stat.uid, stat.mode & 0o7777]
    end

    def check_virtiofs_directory(proof)
      State.new(proof.fetch(:directory), 'virtiofs-path').check_ancestors(proof.fetch(:directory))
      begin
        named = virtiofs_identity(File.lstat(proof.fetch(:directory)), 'directory', 0o700)
      rescue Errno::ENOENT
        return false
      end
      opened = proof[:directory_fd]
      # Closed pins belong only to retired, absent paths. They can never
      # authorize deletion of a path that reappears after retirement.
      raise Error, 'virtiofs directory pin is unavailable' if (!opened || opened.closed?) && !proof[:absent]
      pinned = opened && !opened.closed? ? virtiofs_identity(opened.stat, 'directory', 0o700) : proof.fetch(:directory_identity)
      raise Error, 'virtiofs listener directory changed' unless named == pinned && pinned == proof.fetch(:directory_identity)
      true
    end

    def check_virtiofs_path(proof)
      raise Error, 'virtiofs listener cleanup previously refused' if proof[:refused] || !proof[:socket_identity]
      unless check_virtiofs_directory(proof)
        proof[:absent] = true
        return false
      end
      begin
        named = virtiofs_identity(File.lstat(proof.fetch(:path)), 'socket', 0o600)
      rescue Errno::ENOENT
        proof[:absent] = true
        return false
      end
      raise Error, 'virtiofs listener reappeared after removal' if proof[:absent]
      pinned = virtiofs_identity(proof.fetch(:socket_fd).stat, 'socket', 0o600)
      raise Error, 'virtiofs listener changed' unless named == pinned && pinned == proof.fetch(:socket_identity)
      true
    end

    def close_virtiofs_proof(proof)
      begin
        stream = proof[:socket_fd]
        stream&.close unless stream&.closed?
      ensure
        stream = proof[:directory_fd]
        stream&.close unless stream&.closed?
      end
    end
  end

  module PreparedDisks
    def bind_preparation(state, artifact)
      @kb_preparation = DiskPreparation.new(state, artifact)
      self
    end

    protected

    def prepare_disks
      disks = config.disks.to_h do |disk|
        unless disk.type == 'file' && disk.create && /\A[a-zA-Z0-9_.-]+\z/.match?(disk.device)
          raise Error, 'portable artifacts require owned relative file disks'
        end
        [disk.device, { 'path' => disk_path(disk.device) }]
      end
      if config.respond_to?(:disk_image)
        disks['root'] = { 'path' => root_disk_path, 'initial_image' => config.disk_image }
      end
      @kb_preparation.prepare(name, disks) do
        # Skip upstream NixosMachine's unconditional root replacement.
        OsVm::Machine.instance_method(:prepare_disks).bind_call(self)
        if disks.key?('root')
          File.open(root_disk_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |destination|
            IO.copy_stream(config.disk_image, destination)
            destination.flush
            destination.fsync
          end
        end
        disks.each_value { |disk| File.chmod(0o600, disk.fetch('path')) }
      end
    end
  end

  class NixosMachine < OsVm::NixosMachine
    include PreparedDisks
    include VirtiofsListeners
  end

  class VpsadminosMachine < OsVm::VpsadminosMachine
    include PreparedDisks
    include VirtiofsListeners
  end
end
