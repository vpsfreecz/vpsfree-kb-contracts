#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'

root = File.expand_path(ARGV.fetch(0))
raise 'artifact root must not be in the Nix store' if root == '/nix/store' || root.start_with?('/nix/store/')
current = root
loop do
  raise 'symlink in artifact root' if File.symlink?(current)
  break if current == '/'
  current = File.dirname(current)
end
raise 'artifact root must be an owned writable directory' unless File.directory?(root) && File.stat(root).uid == Process.uid && File.writable?(root) && (File.stat(root).mode & 0o022).zero?
temporary = File.join(root, 'tmp')
Dir.mkdir(temporary, 0o700) unless File.exist?(temporary)
raise 'unsafe artifact temporary directory' unless !File.symlink?(temporary) && File.directory?(temporary) && File.stat(temporary).uid == Process.uid && (File.stat(temporary).mode & 0o022).zero?
lock_path = File.join(temporary, 'capture.lock')
inherited = ARGV[1] == '--inherited-fd'
raise 'artifact descriptor must be explicitly inherited as fd3' if inherited && (ARGV[2] != '3' || ARGV.length != 3)
unless inherited
  begin
    File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) {}
  rescue Errno::EEXIST
    # Existing captures/validators share the same persistent lock.
  end
end
stat = File.lstat(lock_path)
raise 'unsafe artifact lock' unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600
lock = inherited ? File.for_fd(3, 'r+', autoclose: true) : File.open(lock_path, File::RDWR | File::NOFOLLOW)
begin
  raise 'unsafe artifact descriptor' unless lock.stat.file? && lock.stat.uid == Process.uid && (lock.stat.mode & 0o777) == 0o600
  raise 'artifact lock changed while opening' unless [lock.stat.dev, lock.stat.ino] == [stat.dev, stat.ino]
  lock.flock(File::LOCK_EX)
  if ARGV[1] == '--exec'
    command = ARGV.drop(2)
    raise 'validation command is required' if command.empty?
    pid = Process.spawn(*command, lock.fileno => lock, close_others: true)
    Process.wait(pid)
    exit $?.exitstatus
  end
  $stdout.puts(JSON.generate('schema' => 1, 'kind' => 'kb-artifact-lock'))
  $stdout.flush
  $stdin.read
ensure
  # Closing duplicates preserves the shared flock until the last writer closes.
  # Never LOCK_UN: capture and validator children retain this same description.
  lock.close
end
