# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module KbRuntime
  Error = Class.new(StandardError)
  Busy = Class.new(Error)

  # Portable state has no session, package-generation or workspace authority.
  class State
    SCHEMA = 2
    SLUG = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z/
    UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
    attr_reader :root, :slug, :directory

    def initialize(root, slug)
      raise Error, 'invalid cluster slug' unless SLUG.match?(slug)

      @root = File.expand_path(root)
      @slug = slug
      @directory = File.join(@root, 'clusters', slug)
      check_ancestors(@root)
    end

    def check_ancestors(path)
      current = File.expand_path(path)
      loop do
        raise Error, "symlink in state path: #{current}" if File.symlink?(current)
        raise Error, "non-directory state ancestor: #{current}" if File.exist?(current) && !File.directory?(current)
        break if current == '/'

        current = File.dirname(current)
      end
    end

    def private_directory(path, create: false)
      check_ancestors(path)
      if !File.exist?(path)
        return false unless create

        parent = File.dirname(path)
        private_directory(parent, create: true) unless File.directory?(parent)
        begin
          Dir.mkdir(path, 0o700)
        rescue Errno::EEXIST
          # Another initializer must still satisfy the same identity checks.
        end
      end
      stat = File.lstat(path)
      raise Error, "unsafe private directory: #{path}" unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700

      true
    end

    def file(path, limit: 2 * 1024 * 1024)
      check_ancestors(File.dirname(path))
      stat = File.lstat(path)
      raise Error, "unsafe private file: #{path}" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600 && stat.size <= limit

      File.open(path, File::RDONLY | File::NOFOLLOW) do |stream|
        opened = stream.stat
        raise Error, "file changed while opening: #{path}" unless [opened.dev, opened.ino] == [stat.dev, stat.ino]

        (stream.read(limit + 1) || '').tap { |bytes| raise Error, 'file exceeds size limit' if bytes.bytesize > limit }
      end
    end

    def read(path, **opts)
      JSON.parse(file(path, **opts))
    rescue JSON::ParserError
      raise Error, "invalid JSON: #{path}"
    end

    def write(path, value, immutable: false)
      private_directory(File.dirname(path)) || raise(Error, 'state parent is absent')
      raise Error, "immutable record already exists: #{path}" if immutable && (File.exist?(path) || File.symlink?(path))
      file(path) if File.exist?(path) || File.symlink?(path)
      temporary = "#{path}.#{SecureRandom.hex(12)}"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |stream|
          stream.write("#{JSON.generate(value)}\n")
          stream.flush
          stream.fsync
        end
        File.rename(temporary, path)
        File.open(File.dirname(path), &:fsync)
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end
    end

    def path(name)
      raise Error, 'invalid state record name' unless /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/.match?(name)

      File.join(directory, name)
    end

    def identity
      private_directory(root) || raise(Error, 'state root is absent')
      private_directory(File.join(root, 'clusters')) || raise(Error, 'cluster inventory is absent')
      private_directory(directory) || raise(Error, 'cluster is absent')
      value = read(path('identity.json'), limit: 8192)
      expected = %w[schema instance_id owner_uid state_root slug created_at]
      unless value.keys.sort == expected.sort && value['schema'] == SCHEMA && UUID.match?(value['instance_id'].to_s) && value['owner_uid'] == Process.uid && value['state_root'] == root && value['slug'] == slug && File.realpath(root) == root
        raise Error, 'unsupported or foreign cluster identity; legacy state is not adopted'
      end
      Time.iso8601(value.fetch('created_at'))
      value
    end

    def initialize_identity
      private_directory(root, create: true)
      private_directory(File.join(root, 'clusters'), create: true)
      if File.exist?(directory) || File.symlink?(directory)
        return identity
      end
      temporary = File.join(root, 'clusters', ".#{slug}.#{SecureRandom.hex(12)}")
      private_directory(temporary, create: true)
      value = { 'schema' => SCHEMA, 'instance_id' => SecureRandom.uuid, 'owner_uid' => Process.uid,
                'state_root' => root, 'slug' => slug, 'created_at' => Time.now.utc.iso8601 }
      write(File.join(temporary, 'identity.json'), value, immutable: true)
      File.rename(temporary, directory)
      File.open(File.dirname(directory), &:fsync)
      identity
    end

    # Gates and operation locks survive reset. Reads never create lock/state files.
    def lock(kind, create: false, shared: false, wait: true)
      raise Error, 'unknown lock kind' unless %w[gate operation runner].include?(kind)
      private_directory(root, create:) || raise(Error, 'state root is absent')
      locks = File.join(root, 'locks')
      private_directory(locks, create:) || raise(Error, 'lock inventory is absent')
      name = File.join(locks, "#{slug}.#{kind}.lock")
      if !File.exist?(name) && create
        begin
          File.open(name, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) {}
        rescue Errno::EEXIST
          # Validate the winner below.
        end
      end
      file(name, limit: 0)
      expected = File.lstat(name)
      stream = File.open(name, File::RDWR | File::NOFOLLOW)
      raise Error, 'lock changed while opening' unless [stream.stat.dev, stream.stat.ino] == [expected.dev, expected.ino]
      flags = shared ? File::LOCK_SH : File::LOCK_EX
      flags |= File::LOCK_NB unless wait
      raise Busy, 'cluster operation or capture is busy' unless stream.flock(flags)

      yield stream
    ensure
      stream&.close
    end

    def transaction(create: false, wait: true)
      lock('gate', create:, wait:) { lock('operation', create:, wait:) { yield } }
    end
  end
end
