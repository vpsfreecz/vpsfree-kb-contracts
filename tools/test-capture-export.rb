# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'digest'
require 'fileutils'
require 'shellwords'
require 'test-runner/hook'
require 'osvm'
TestRunner::Hook.register(:after_test_script_run)
require_relative '../tests/runner/extensions/kb_capture_artifacts'

class CaptureEvidenceExportTest < Minitest::Test
  def test_pinned_machine_succeeds_returns_status_and_output_without_a_vm
    shell = Object.new
    shell.define_singleton_method(:succeeds) { |_command, timeout:| [0, 'fixture output'] }
    machine = OsVm::Machine.allocate
    machine.define_singleton_method(:command_shell) { |_name| shell }
    result = machine.succeeds('not executed', timeout: 1)
    assert_equal([0, 'fixture output'], result)
    assert_equal('fixture output', result.last)
    source, = machine.method(:succeeds).source_location
    assert(source.start_with?(ENV.fetch('VPSADMIN_KB_OSVM_SOURCE') + '/'))
  end

  class Machine
    attr_reader :pulled
    attr_accessor :corrupt

    def initialize(directory)
      @directory, @pulled = directory, []
    end

    def succeeds(command)
      path = Shellwords.split(command).last
      [0, "#{Digest::SHA256.file(local(path)).hexdigest}  #{path}\n"]
    end

    def pull_file(path)
      @pulled << path
      result = File.join(@directory, 'pulled')
      File.write(result, @corrupt ? 'corrupt' : File.binread(local(path)))
      result
    end

    def local(path)
      File.join(@directory, path.delete_prefix(KbCaptureArtifacts::OUTPUT_ROOT + '/'))
    end
  end

  def with_machine
    Dir.mktmpdir('kb-evidence-') do |directory|
      machine = Machine.new(directory)
      (KbCaptureArtifacts::FILES + ['credentials/id_ed25519', 'connection.json', 'tmp/transcript.log']).each do |relative|
        file = File.join(directory, relative)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "fixture #{relative}")
      end
      yield machine, File.join(directory, 'runner-state')
    end
  end

  def invoke(machine, state_dir, success:, suite: 'runtime/standalone', script: 'bilingual-capture')
    result = Struct.new(:successful?).new(success)
    TestRunner::Hook.call(:after_test_script_run, kwargs: {
      test: Struct.new(:path).new(suite), script: Struct.new(:name).new(script),
      script_result: result, machines: { 'machine' => machine }, state_dir:
    })
  end

  def test_success_exports_only_allowlisted_relative_paths_and_verifies_each_hash
    with_machine do |machine, state_dir|
      invoke(machine, state_dir, success: true)
      destination = File.join(state_dir, 'artifacts/kb-runtime-standalone/bilingual-capture')
      actual = Dir.glob(File.join(destination, '**/*')).select { |path| File.file?(path) }.map { |path| path.delete_prefix(destination + '/') }
      assert_equal(KbCaptureArtifacts::FILES.sort, actual.sort)
      assert_equal(KbCaptureArtifacts::FILES.map { |name| "#{KbCaptureArtifacts::OUTPUT_ROOT}/#{name}" }, machine.pulled)
      KbCaptureArtifacts::FILES.each do |relative|
        assert_equal("fixture #{relative}", File.read(File.join(destination, relative)))
      end
      assert_raises(RuntimeError) { invoke(machine, state_dir, success: true) }
    end
  end

  def test_failed_or_other_scripts_do_not_pull_any_evidence
    with_machine do |machine, state_dir|
      invoke(machine, state_dir, success: false)
      invoke(machine, state_dir, success: true, script: 'installed-layout')
      invoke(machine, state_dir, success: true, suite: 'kb/firewall')
      assert_empty(machine.pulled)
      refute(File.exist?(state_dir))
    end
  end

  def test_transfer_hash_mismatch_fails_before_retaining_that_file
    with_machine do |machine, state_dir|
      machine.corrupt = true
      error = assert_raises(RuntimeError) { invoke(machine, state_dir, success: true) }
      assert_match(/pulled artifact hash differs/, error.message)
      refute(File.exist?(File.join(state_dir, 'artifacts/kb-runtime-standalone/bilingual-capture', KbCaptureArtifacts::FILES.first)))
    end
  end
end
