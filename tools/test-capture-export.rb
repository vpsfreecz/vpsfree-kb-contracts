# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'digest'
require 'fileutils'
require 'osvm'
require_relative 'capture-export'

class CaptureEvidenceExportTest < Minitest::Test
  def test_pinned_machine_succeeds_returns_status_and_output_without_a_vm
    shell = Object.new
    shell.define_singleton_method(:succeeds) { |_command, timeout:| [0, 'fixture output'] }
    machine = OsVm::Machine.allocate
    machine.define_singleton_method(:command_shell) { |_name| shell }
    assert_equal([0, 'fixture output'], machine.succeeds('not executed', timeout: 1))
    source, = machine.method(:succeeds).source_location
    assert(source.start_with?(ENV.fetch('VPSADMIN_KB_OSVM_SOURCE') + '/'))
  end

  def with_output
    Dir.mktmpdir('kb-evidence-') do |root|
      File.chmod(0o700, root)
      (KbCaptureArtifacts::FILES + ['credentials/id_ed25519', 'connection.json', 'tmp/transcript.log']).each do |relative|
        file = File.join(root, 'output', relative)
        FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
        File.write(file, "fixture #{relative}", perm: 0o600)
      end
      File.write(File.join(root, 'output/tmp/capture.lock'), '', perm: 0o600)
      yield File.join(root, 'output'), File.join(root, 'export')
    end
  end

  def test_exports_only_five_allowlisted_files_and_verifies_their_hashes
    with_output do |output, destination|
      result = KbCaptureArtifacts.export(output, destination)
      actual = Dir.glob(File.join(destination, '**/*')).select { |path| File.file?(path) }.map { |path| path.delete_prefix(destination + '/') }
      assert_equal(KbCaptureArtifacts::FILES.sort, actual.sort)
      assert_equal(KbCaptureArtifacts::FILES.sort, result.fetch('files').keys.sort)
      KbCaptureArtifacts::FILES.each do |relative|
        assert_equal("fixture #{relative}", File.read(File.join(destination, relative)))
        assert_equal(Digest::SHA256.file(File.join(destination, relative)).hexdigest, result['files'][relative])
      end
      assert_raises(RuntimeError) { KbCaptureArtifacts.export(output, destination) }
    end
  end

  def test_symlink_or_existing_destination_cannot_export_or_overwrite
    with_output do |output, destination|
      target = File.join(output, KbCaptureArtifacts::FILES.first)
      File.unlink(target)
      File.symlink(File.join(output, 'credentials/id_ed25519'), target)
      assert_raises(RuntimeError) { KbCaptureArtifacts.export(output, destination) }
      refute(File.exist?(File.join(destination, KbCaptureArtifacts::FILES.first)))
    end
  end

  def test_export_waits_for_physical_output_lock_and_copies_after_release
    with_output do |output, destination|
      reader, ready = IO.pipe
      release, writer = IO.pipe
      pid = fork do
        reader.close; writer.close
        File.open(File.join(output, 'tmp/capture.lock'), File::RDWR) do |lock|
          lock.flock(File::LOCK_EX)
          ready.write('held'); ready.close
          release.read
        end
        exit! 0
      end
      ready.close; release.close
      assert_equal('held', reader.read)
      exported = Thread.new { KbCaptureArtifacts.export(output, destination) }
      refute(exported.join(0.1), 'independent lock holder must exclude export')
      refute(File.exist?(destination))
      writer.close
      Process.wait(pid); pid = nil
      assert_equal(KbCaptureArtifacts::FILES.sort, exported.value.fetch('files').keys.sort)
    ensure
      writer&.close unless writer&.closed?
      reader&.close unless reader&.closed?
      Process.wait(pid) if pid
      exported&.join
    end
  end
end
