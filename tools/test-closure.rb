# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'open3'
require 'tmpdir'
require_relative '../cluster/lib/kb_closure'

class ClosureEngineFixture
  attr_reader :state, :calls
  attr_accessor :failure, :free_space, :expected

  def initialize(state)
    @state, @calls = state, []
    @free_space = "1073741824\n100000\n"
  end

  def artifact_digest(_value)
    'a' * 64
  end

  def verify_live(record)
    calls << [:attest, record['run_id']]
    raise KbRuntime::Error, 'old guest source differs' if failure == :source
  end

  def ssh(record, machine, *argv, input: nil)
    calls << [:ssh, record['run_id'], machine, argv, input]
    raise KbRuntime::Error, 'guest store tools missing' if failure == :tools && argv.join(' ').include?('command -v nix')
    return '' if argv.join(' ').include?('--check-validity')
    return free_space if argv.join(' ').include?('df -B1')
    if argv.first == 'nix'
      return JSON.generate(failure == :identity ? expected.merge('/unexpected' => expected.values.first) : expected)
    end
    raise KbRuntime::Error, 'guest content differs' if failure == :content && argv.first == 'nix-store'
    raise KbRuntime::Error, 'guest GC root failed' if failure == :root && input
    raise KbRuntime::Error, 'second machine interrupted' if failure == :second && machine == 'helper'
    ''
  end
end

class ClosurePreparationTest < Minitest::Test
  def with_preparation
    Dir.mktmpdir('kb-closure-') do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'closure-test')
      identity = state.transaction(create: true) { state.initialize_identity }
      engine = ClosureEngineFixture.new(state)
      path = "/nix/store/#{'0' * 32}-candidate"
      expected = { path => { 'narHash' => 'sha256-candidate', 'narSize' => 4096, 'references' => [path] } }
      engine.expected = expected
      preparation = KbRuntime::ClosurePreparation.new(engine)
      preparation.define_singleton_method(:host_info) { |_toplevel| expected }
      preparation.define_singleton_method(:inode_count) { |_paths| 42 }
      old = identity.merge('run_id' => SecureRandom.uuid,
        'endpoints' => { 'services' => { 'host' => '127.0.0.9', 'port' => 12345 }, 'helper' => { 'host' => '127.0.0.10', 'port' => 12346 } })
      artifact = { 'instance_id' => identity['instance_id'], 'artifact_id' => SecureRandom.uuid,
        'layout' => { 'services' => { 'spin' => 'nixos' } }, 'machine_toplevels' => { 'services' => path } }
      yield engine, preparation, old, artifact, expected
    end
  end

  def test_exact_import_uses_old_endpoint_key_port_and_clears_inherited_overrides
    with_preparation do |engine, preparation, old, artifact, expected|
      variables = %w[NIX_REMOTE NIX_SSHOPTS NIX_CONFIG SSH_AUTH_SOCK VPSADMIN_DEVCLUSTER_VPSADMIN_SOURCE]
      originals = variables.to_h { |name| [name, ENV[name]] }
      variables.each { |name| ENV[name] = 'conflicting ambient value' }
      copies = []
      command = lambda do |*argv, env:|
        copies << [argv, env]
        ''
      end
      KbRuntime::Software.stub(:command, command) { preparation.prepare(old, artifact) }
      assert_equal(1, copies.size)
      argv, environment = copies.first
      assert_equal(['nix', 'copy', '--to', 'ssh://root@127.0.0.9', artifact['machine_toplevels']['services']], argv)
      assert_includes(environment['NIX_SSHOPTS'], '-p 12345')
      assert_includes(environment['NIX_SSHOPTS'], 'StrictHostKeyChecking\=yes')
      assert_includes(environment['NIX_SSHOPTS'], 'known_hosts')
      (variables - ['NIX_SSHOPTS']).each { |name| assert_nil(environment[name]) }
      receipt = engine.state.read(engine.state.path("prepared-#{artifact['artifact_id']}-services.json"))
      assert_equal(expected, receipt['closure'])
      assert_equal(old['run_id'], receipt['old_run_id'])
      assert_equal(artifact['artifact_id'], receipt['artifact_id'])
      assert(receipt['complete'])
      assert_includes(receipt['guest_root'], "/#{old['instance_id']}/#{artifact['artifact_id']}/services")
      assert(engine.state.read(engine.state.path("prepared-#{artifact['artifact_id']}.json"))['complete'])
      assert_equal([:attest, old['run_id']], engine.calls.last)
    ensure
      originals&.each { |name, value| ENV[name] = value }
    end
  end

  [:source, :tools, :identity, :content, :root, :second, :space, :inodes, :copy].each do |failure|
    define_method("test_#{failure}_failure_cannot_certify_complete_preparation") do
      with_preparation do |engine, preparation, old, artifact, _expected|
        if failure == :second
          artifact['layout']['helper'] = { 'spin' => 'nixos' }
          artifact['machine_toplevels']['helper'] = artifact['machine_toplevels']['services']
        end
        engine.failure = failure
        engine.free_space = '1 100000' if failure == :space
        engine.free_space = "1073741824 #{KbRuntime::ClosurePreparation::RESERVE_INODES}" if failure == :inodes
        command = lambda do |*_argv, env:|
          raise KbRuntime::Error, 'copy ENOSPC' if failure == :copy
          ''
        end
        assert_raises(KbRuntime::Error) do
          KbRuntime::Software.stub(:command, command) { preparation.prepare(old, artifact) }
        end
        refute(File.exist?(engine.state.path("prepared-#{artifact['artifact_id']}.json")))
        assert(engine.calls.all? { |call| call[1] == old['run_id'] })
        if failure == :second
          assert(engine.state.read(engine.state.path("prepared-#{artifact['artifact_id']}-services.json"))['complete'])
        end
      end
    end
  end

  def test_host_closure_queries_and_verifies_every_path_content
    engine = Object.new
    preparation = KbRuntime::ClosurePreparation.new(engine)
    top = "/nix/store/#{'0' * 32}-system"
    dependency = "/nix/store/#{'1' * 32}-dependency"
    information = [
      { 'path' => top, 'narHash' => 'sha256-top', 'narSize' => 10, 'references' => [dependency] },
      { 'path' => dependency, 'narHash' => 'sha256-dependency', 'narSize' => 20, 'references' => [] }
    ]
    calls = []
    command = lambda do |*argv, env:|
      calls << argv
      argv.first == 'nix' ? JSON.generate(information) : ''
    end
    KbRuntime::Software.stub(:command, command) do
      assert_equal([top, dependency].sort, preparation.host_info(top).keys)
    end
    assert_equal([['nix-store', '--verify-path', top], ['nix-store', '--verify-path', dependency]].sort,
      calls.select { |argv| argv.first == 'nix-store' }.sort)
  end

  def test_inode_estimate_does_not_follow_symlinks_outside_the_closure
    Dir.mktmpdir('kb-inodes-') do |directory|
      closure = File.join(directory, 'closure')
      FileUtils.mkdir_p(File.join(closure, 'subdirectory'))
      File.write(File.join(closure, 'file'), 'data')
      File.symlink(directory, File.join(closure, 'subdirectory', 'link'))
      assert_equal(4, KbRuntime::ClosurePreparation.new(Object.new).inode_count([closure]))
    end
  end

  def with_native_capacity(engine, producer: nil, output: '', exit_status: 0)
    df = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, 'df') }
      .find { |path| File.file?(path) && File.executable?(path) }
    refute_nil(df, 'the declared shell must provide GNU df')
    assert_match(%r{\A/nix/store/}, File.realpath(df))
    version, _stderr, status = Open3.capture3(df, '--version')
    assert(status.success?)
    assert_match(/\Adf \(GNU coreutils\)/, version)
    original = engine.method(:ssh)
    observations = []
    Dir.mktmpdir('kb-capacity-producer-') do |directory|
      trace = File.join(directory, 'df-argv')
      wrapper = File.join(directory, 'df')
      File.write(wrapper, <<~SH)
        #!/bin/sh
        set -eu
        printf '%s\\n' "$*" >> #{Shellwords.escape(trace)}
        if test "$1" = '-B1'; then field=bytes; else field=inodes; fi
        if test "$field" = #{Shellwords.escape(producer.to_s)}; then
          printf '%s' #{Shellwords.escape(output)}
          printf '%s\\n' 'controlled df diagnostic' >&2
          exit #{Integer(exit_status)}
        fi
        exec #{Shellwords.escape(df)} "$@"
      SH
      File.chmod(0o700, wrapper)
      engine.define_singleton_method(:ssh) do |record, machine, *argv, input: nil|
        if argv.first(2) == ['sh', '-c'] && argv.last.include?('df -B1')
          calls << [:ssh, record['run_id'], machine, argv, input]
          stdout, stderr, result = Open3.capture3({ 'PATH' => "#{directory}:#{ENV.fetch('PATH')}" }, *argv)
          observations << { argv: argv, stdout: stdout, stderr: stderr, status: result,
            producers: File.readlines(trace, chomp: true) }
          raise KbRuntime::Error, "guest capacity command failed (exit #{result.exitstatus})" unless result.success?

          stdout
        else
          original.call(record, machine, *argv, input: input)
        end
      end
      yield observations
    end
  ensure
    engine.define_singleton_method(:ssh, original) if original
  end

  def test_actual_capacity_shell_uses_native_gnu_df_before_copy_and_complete_receipts
    with_preparation do |engine, preparation, old, artifact, _expected|
      copies = []
      with_native_capacity(engine) do |observations|
        command = ->(*argv, env:) { copies << [argv, env]; '' }
        KbRuntime::Software.stub(:command, command) { preparation.prepare(old, artifact) }
        assert_equal(1, observations.length)
        native = observations.first
        assert(native[:status].success?, native[:stderr])
        assert_equal(['-B1 --output=avail /nix/store', '--output=iavail /nix/store'], native[:producers])
        assert_match(/\A\s*\d+\s+\d+\s*\z/, native[:stdout])
        assert_equal(1, copies.length)
        assert_equal(['nix', 'copy'], copies.first.first.first(2))
        assert(engine.state.read(engine.state.path("prepared-#{artifact['artifact_id']}-services.json"))['complete'])
        assert(engine.state.read(engine.state.path("prepared-#{artifact['artifact_id']}.json"))['complete'])
      end
    end
  end

  %i[bytes inodes].each do |producer|
    define_method("test_#{producer}_native_df_failure_cannot_reach_copy_or_prepared_receipt") do
      with_preparation do |engine, preparation, old, artifact, _expected|
        with_native_capacity(engine, producer: producer, output: "measurement that must not be parsed\n", exit_status: 41) do |observations|
          copy = ->(*_argv, env:) { flunk('failed capacity cannot invoke nix copy') }
          error = assert_raises(KbRuntime::Error) do
            KbRuntime::Software.stub(:command, copy) { preparation.prepare(old, artifact) }
          end
          assert_equal('guest capacity command failed (exit 41)', error.message)
          assert_equal(1, observations.length)
          native = observations.first
          assert_equal(41, native[:status].exitstatus)
          assert_equal('', native[:stdout], 'no numeric lines may be published before both df commands succeed')
          assert_equal("controlled df diagnostic\n", native[:stderr])
          expected = ['-B1 --output=avail /nix/store']
          expected << '--output=iavail /nix/store' if producer == :inodes
          assert_equal(expected, native[:producers])
          refute(File.exist?(engine.state.path("prepared-#{artifact['artifact_id']}-services.json")))
          refute(File.exist?(engine.state.path("prepared-#{artifact['artifact_id']}.json")))
          assert(engine.calls.all? { |call| call[1] == old['run_id'] })
        end
      end
    end
  end

  %i[bytes inodes].product([['missing', ''], ['malformed', "not-a-number\n"]]).each do |producer, (label, output)|
    define_method("test_successful_#{producer}_df_with_#{label}_measurement_refuses_before_copy_or_prepared_receipt") do
      with_preparation do |engine, preparation, old, artifact, _expected|
        with_native_capacity(engine, producer: producer, output: output) do |observations|
          copy = ->(*_argv, env:) { flunk('invalid measurements cannot invoke nix copy') }
          assert_raises(KbRuntime::Error, ArgumentError) do
            KbRuntime::Software.stub(:command, copy) { preparation.prepare(old, artifact) }
          end
          assert_equal(1, observations.length)
          assert(observations.first[:status].success?)
          assert_equal(['-B1 --output=avail /nix/store', '--output=iavail /nix/store'], observations.first[:producers])
          refute(File.exist?(engine.state.path("prepared-#{artifact['artifact_id']}-services.json")))
          refute(File.exist?(engine.state.path("prepared-#{artifact['artifact_id']}.json")))
          assert(engine.calls.all? { |call| call[1] == old['run_id'] })
        end
      end
    end
  end
end
