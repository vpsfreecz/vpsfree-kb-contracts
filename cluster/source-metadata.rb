#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/kb_source'

if ARGV[0] == '--validation'
  root, receipt_file, metadata_file = ARGV.drop(1)
  receipt = JSON.parse(File.read(receipt_file))
  metadata = metadata_file ? JSON.parse(File.read(metadata_file)) : receipt.fetch('source')
  software = KbRuntime::Software.new(metadata)
  raise KbRuntime::Error, 'validation input lock differs' unless Digest::SHA256.file(File.join(root, 'flake.lock')).hexdigest == metadata.fetch('lock_sha256')
  raise KbRuntime::Error, 'validation fixtures differ' unless KbRuntime::Software.fixture_digest(root) == metadata.fetch('fixture_sha256')
  unless metadata_file
    revision = KbRuntime::Software.command('git', '-C', root, 'rev-parse', 'HEAD')
    raise KbRuntime::Error, 'validation K revision differs' unless revision == metadata.fetch('revision')
    changed = KbRuntime::Software.command('git', '-C', root, 'status', '--porcelain', '--untracked-files=all')
    raise KbRuntime::Error, 'validation source code has changed' unless changed.lines.all? { |line| line[3..].strip.match?(%r{\A(?:captures\.json|screenshots/(?:cs|en)/[a-z0-9-]+/[a-z0-9-]+\.png)\z}) }
  end
  puts JSON.generate(software.metadata)
elsif ARGV[0] == '--checkout'
  puts JSON.generate(KbRuntime::Software.checkout(ARGV.fetch(1)).metadata)
else
  root, revision = ARGV
  lock = JSON.parse(File.read(File.join(root, 'flake.lock')))
  puts JSON.generate('schema' => 1, 'revision' => revision, 'source' => root,
                     'lock_sha256' => Digest::SHA256.file(File.join(root, 'flake.lock')).hexdigest,
                     'fixture_sha256' => KbRuntime::Software.fixture_digest(root),
                     'inputs' => KbRuntime::Software.locked_inputs(lock))
end
