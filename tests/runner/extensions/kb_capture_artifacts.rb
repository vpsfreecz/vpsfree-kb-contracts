# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'shellwords'
require 'test-runner/hook'

module KbCaptureArtifacts
  OUTPUT_ROOT = '/tmp/kb-capture-evidence'
  FILES = %w[
    screenshots/cs/networking/ip-address-list.png
    screenshots/en/networking/ip-address-list.png
    captures.json
    tmp/capture-results.json
    tmp/capture-source.json
  ].freeze

  def self.export(machine, state_dir)
    destination = File.join(state_dir, 'artifacts', 'kb-runtime-standalone', 'bilingual-capture')
    raise 'KB capture evidence destination already exists' if File.exist?(destination)

    FileUtils.mkdir_p(destination)
    FILES.each do |relative|
      source = File.join(OUTPUT_ROOT, relative)
      _, output = machine.succeeds("sha256sum -- #{Shellwords.escape(source)}")
      expected = output.split.first
      raise 'invalid guest artifact hash' unless /\A[0-9a-f]{64}\z/.match?(expected.to_s)

      pulled = machine.pull_file(source)
      raise "pulled artifact hash differs: #{relative}" unless Digest::SHA256.file(pulled).hexdigest == expected

      target = File.join(destination, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.copy_file(pulled, target)
      raise "retained artifact hash differs: #{relative}" unless Digest::SHA256.file(target).hexdigest == expected
    end
    destination
  end
end

TestRunner::Hook.subscribe(:after_test_script_run) do |test:, script:, script_result:, machines:, state_dir:, **|
  next unless test.path == 'runtime/standalone' && script.name == 'bilingual-capture' && script_result.successful?

  KbCaptureArtifacts.export(machines.fetch('machine'), state_dir)
end
