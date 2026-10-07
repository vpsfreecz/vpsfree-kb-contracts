# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative '../cluster/lib/kb_state'

module KbCaptureArtifacts
  FILES = %w[
    screenshots/cs/networking/ip-address-list.png
    screenshots/en/networking/ip-address-list.png
    captures.json
    tmp/capture-results.json
    tmp/capture-source.json
  ].freeze

  def self.export(output_root, destination)
    output_root = File.realpath(output_root)
    state = KbRuntime::State.new(output_root, 'export')
    state.private_directory(output_root) || raise('output root is absent')
    lock_path = File.join(output_root, 'tmp/capture.lock')
    state.file(lock_path, limit: 0)
    expected_lock = File.lstat(lock_path)
    File.open(lock_path, File::RDWR | File::NOFOLLOW) do |lock|
      raise 'artifact lock identity changed' unless [lock.stat.dev, lock.stat.ino] == [expected_lock.dev, expected_lock.ino]
      lock.flock(File::LOCK_EX)
      raise 'KB capture evidence destination already exists' if File.exist?(destination) || File.symlink?(destination)
      state.private_directory(File.dirname(destination)) || raise('export parent is not private')
      Dir.mkdir(destination, 0o700)
      hashes = {}
      FILES.each do |relative|
        source = File.join(output_root, relative)
        state.check_ancestors(File.dirname(source))
        stat = File.lstat(source)
        raise 'unsafe source artifact' unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
        target = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
          raise 'source artifact changed while opening' unless [input.stat.dev, input.stat.ino] == [stat.dev, stat.ino]
          File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |output| IO.copy_stream(input, output); output.flush; output.fsync }
        end
        expected = Digest::SHA256.file(source).hexdigest
        raise "retained artifact hash differs: #{relative}" unless Digest::SHA256.file(target).hexdigest == expected
        hashes[relative] = expected
      end
      { 'files' => hashes, 'destination' => File.realpath(destination) }
    end
  end
end
