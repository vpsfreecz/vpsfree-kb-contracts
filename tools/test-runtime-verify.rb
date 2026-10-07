# frozen_string_literal: true
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'timeout'
require_relative 'runtime-verify'

class RuntimeVerifyTest < Minitest::Test
  def configuration(port = 24000)
    { 'services' => { 'memoryMiB' => 2048, 'rootDiskMiB' => 8192 },
      'nodes' => { 'node1' => { 'memoryMiB' => 2048, 'tankDiskGiB' => 8 } },
      'topologies' => { 'single' => ['node1'] }, 'dns' => { 'enable' => false },
      'resolver' => { 'mode' => 'cluster', 'upstreamNameservers' => ['10.0.2.3'] },
      'seed' => { 'users' => [['test-admin', 99, 1], ['test-user1', 1, 9], ['test-user2', 1, 17]].map do |login, level, block_start|
        { 'login' => login, 'password' => "synthetic-#{login}", 'fullName' => "Synthetic #{login}",
          'email' => "#{login}@example.test", 'level' => level, 'namespace' => { 'blockStart' => block_start, 'blockCount' => 8 } }
      end },
      'domains' => { 'api' => 'api.example.test' }, 'tmpDomains' => { 'api' => 'api-tmp.example.test' },
      'local' => { 'bindAddress' => '127.0.0.1', 'multicastPort' => port + 20,
        'ports' => { 'services' => { 'ssh' => port, 'https' => port + 10 }, 'node1' => { 'ssh' => port + 1 } } } }
  end

  def with_campaign(config: configuration)
    Dir.mktmpdir do |directory|
      config_path = File.join(directory, 'config.json')
      File.write(config_path, JSON.pretty_generate(config) + "\n", perm: 0o600)
      metadata = File.join(directory, 'metadata.json')
      File.write(metadata, JSON.generate('schema' => 1, 'revision' => 'a' * 40, 'source' => File.expand_path('..', __dir__)))
      selection = { 'metadata' => metadata, 'source' => File.expand_path('..', __dir__), 'path' => '/nix/store/tools/bin',
        'runtime' => File.join(directory, 'runtime'), 'capture' => '/nix/store/capture', 'node_path' => '/nix/store/node_modules',
        'browsers' => '/nix/store/browser', 'fonts' => '/nix/store/fonts', 'certificates' => '/nix/store/ca',
        'gem_home' => '/nix/store/ruby/lib/ruby/gems' }
      FileUtils.mkdir_p(File.join(selection['runtime'], 'bin'))
      File.write(File.join(selection['runtime'], 'bin/vpsfree-kb-devcluster'), metadata)
      # Pure orchestration fixtures bypass store validation, preserving each
      # supplied metadata value; never nest a stub of the same constructor.
      software = ->(value) { Struct.new(:metadata).new(value) }
      KbRuntime::Software.stub(:new, software) do
        campaign = KbVerify::Campaign.new(root: File.join(directory, 'campaign'), config: config_path,
          capacity_receipt: File.join(directory, 'capacity.json'), selection:)
        write_assessment(campaign, assessment(campaign))
        yield campaign
      end
    end
  end

  def assessment(campaign)
    roles = { 'state_images' => campaign.root, 'store' => '/nix/store', 'builder_scratch' => '/tmp' }.transform_values do |path|
      { 'path' => path, 'device' => 10, 'mountpoint' => '/', 'fstype' => 'ext4' }
    end
    { 'schema' => 1, 'kind' => KbVerify::KIND, 'bindings' => campaign.inputs, 'observed_at' => Time.now.utc.iso8601,
      'roles' => roles, 'owned_output' => { 'allocated_bytes' => 0, 'apparent_bytes' => 0 },
      'realized_paths' => [], 'missing_paths' => [],
      'resource_overheads' => %w[construction runtime_browser].to_h do |name|
        [name, { 'ram_bytes' => 2 * KbVerify::GIB, 'shm_bytes' => KbVerify::GIB, 'assessment' => 'Synthetic assessed margin.' }]
      end,
      'filesystems' => [{ 'device' => 10, 'reserve_bytes' => 16 * KbVerify::GIB, 'retained_growth_bytes' => 3 * KbVerify::GIB,
        'build_headroom_bytes' => 4 * KbVerify::GIB, 'observed_available_bytes' => 200 * KbVerify::GIB,
        'construction_overlap_bytes' => KbVerify::GIB, 'construction_overlap_assessment' => 'Synthetic measured staging/import overlap.' }],
      'capture_assessment' => { 'assessment' => 'Synthetic template/quota assessment.', 'minimum_free_inodes' => 1000,
        'services_memory_bytes' => 128 * 1024**2, 'node_memory_bytes' => 128 * 1024**2, 'template_metadata_bytes' => KbVerify::GIB },
      'build_plan' => { 'scratch_bound' => 'unknown', 'max_jobs' => 1, 'cores' => 1,
        'assessment' => 'Synthetic capacity fixture, not a host-capacity claim.',
        'daemon_scratch_evidence' => 'Synthetic declared daemon scratch directory.',
        'derivations' => ['synthetic cluster-config/runner construction plan'],
        'kernel_substitutions' => ['synthetic pinned-cache substitution evidence'] } }
  end

  def write_assessment(campaign, value)
    File.write(File.join(File.dirname(campaign.root), 'capacity.json'), JSON.generate(value), perm: 0o600)
  end

  def fake_measurements(campaign, available: 200 * KbVerify::GIB)
    campaign.define_singleton_method(:filesystem) do |path|
      { 'path' => path, 'device' => 10, 'mountpoint' => '/', 'fstype' => 'ext4', 'available_bytes' => available }
    end
    campaign.define_singleton_method(:host_capacity) do
      { 'ram_available' => 6 * KbVerify::GIB, 'shm_available' => 5 * KbVerify::GIB }
    end
    campaign.define_singleton_method(:allocation) do |path|
      stat = File.lstat(path)
      { 'path' => path, 'device' => 10, 'inode' => stat.ino, 'allocated_bytes' => stat.blocks * 512, 'apparent_bytes' => stat.size }
    end
  end

  def test_single_profile_accounts_domains_and_dedicated_protocol_ports
    with_campaign do |campaign|
      assert_equal('single-runtime-v1', KbVerify::KIND)
      assert_equal(%w[installed-layout runtime-smoke bilingual-capture], KbVerify::PHASES)
      assert_equal(configuration, campaign.config)
      assert_equal(Digest::SHA256.file(File.join(File.dirname(campaign.root), 'config.json')).hexdigest, campaign.inputs['configuration_sha256'])
      assert_equal(%w[test-admin test-user1 test-user2], campaign.config.dig('seed', 'users').map { |entry| entry['login'] })
      refute(campaign.inputs.key?('predecessor_ref'))
      refute(campaign.inputs.key?('configurations'))
    end
    %w[memory root tank nodes dns resolver domain bind port].each do |wrong|
      candidate = configuration
      case wrong
      when 'memory' then candidate['services']['memoryMiB'] = 4096
      when 'root' then candidate['services']['rootDiskMiB'] = 12288
      when 'tank' then candidate['nodes']['node1']['tankDiskGiB'] = 16
      when 'nodes' then candidate['nodes']['node2'] = candidate['nodes']['node1'].dup
      when 'dns' then candidate['dns']['enable'] = true
      when 'resolver' then candidate['resolver']['upstreamNameservers'] = ['192.0.2.1']
      when 'domain' then candidate['domains']['api'] = 'api.invalid'
      when 'bind' then candidate['local']['bindAddress'] = '0.0.0.0'
      when 'port' then candidate['local']['ports']['node1']['ssh'] = candidate['local']['ports']['services']['ssh']
      end
      assert_raises(KbVerify::Error) { with_campaign(config: candidate) { flunk('invalid profile admitted') } }
    end
    # TCP and UDP remain distinct protocols, even for the same numeric port.
    candidate = configuration
    candidate['local']['multicastPort'] = candidate['local']['ports']['services']['ssh']
    with_campaign(config: candidate) { |campaign| assert_equal(candidate, campaign.config) }
  end

  def test_explicit_admin_and_members_refuse_missing_duplicate_role_auth_identity_and_namespace
    %w[missing duplicate role password identity namespace member].each do |wrong|
      candidate = configuration
      users = candidate.fetch('seed').fetch('users')
      admin = users.find { |account| account['login'] == 'test-admin' }
      case wrong
      when 'missing' then users.delete(admin)
      when 'duplicate' then users << admin.dup
      when 'role' then admin['level'] = 1
      when 'password' then admin.delete('password')
      when 'identity' then admin['email'] = 'not-synthetic.invalid'
      when 'namespace' then admin['namespace']['blockStart'] = 9
      when 'member' then users.find { |account| account['login'] == 'test-user1' }['level'] = 99
      end
      assert_raises(KbVerify::Error) { with_campaign(config: candidate) { flunk('invalid account admitted') } }
    end
  end

  def test_obsolete_cli_arguments_and_unknown_phase_refuse_before_campaign_construction
    calls = []
    constructor = ->(**options) { calls << options; flunk('invalid CLI reached campaign') }
    KbVerify::Campaign.stub(:new, constructor) do
      %w[--config-a --config-b --predecessor-ref].each do |argument|
        _out, error = capture_io { assert_equal(1, KbVerify.run([argument, 'obsolete'])) }
        assert_match(/invalid option/, error)
      end
      capture_io { assert_equal(1, KbVerify.run([])) }
    end
    assert_empty(calls)
    with_campaign do |campaign|
      assert_raises(KbVerify::Error) { campaign.run('isolation-continuity-update') }
      refute(File.exist?(campaign.root))
    end
  end

  def test_nonempty_unowned_old_kind_or_changed_inputs_are_never_adopted
    with_campaign do |campaign|
      Dir.mkdir(campaign.root, 0o700)
      File.write(campaign.file('foreign'), 'retain')
      assert_raises(KbVerify::Error) { campaign.initialize_campaign }
      assert_equal('retain', File.read(campaign.file('foreign')))
      refute(File.exist?(campaign.file('campaign.json')))
    end
    with_campaign do |campaign|
      campaign.initialize_campaign
      identity = campaign.read('campaign.json')
      identity['kind'] = 'historical-two-root'
      campaign.write('campaign.json', identity)
      before = File.binread(campaign.file('campaign.json'))
      assert_raises(KbVerify::Error) { campaign.initialize_campaign }
      assert_equal(before, File.binread(campaign.file('campaign.json')))
      campaign.write('campaign.json', identity.merge('kind' => KbVerify::KIND))
      campaign.inputs['configuration']['local']['multicastPort'] += 1
      before = File.binread(campaign.file('campaign.json'))
      assert_raises(KbVerify::Error) { campaign.initialize_campaign }
      assert_equal(before, File.binread(campaign.file('campaign.json')))
    end
  end

  def test_wrong_selected_source_or_runtime_metadata_refuses_before_root_creation
    with_campaign do |campaign|
      directory = File.dirname(campaign.root)
      source = campaign.source.merge('source' => '/wrong/source')
      File.write(campaign.selection['metadata'], JSON.generate(source))
      assert_raises(KbVerify::Error) do
        KbVerify::Campaign.new(root: campaign.root, config: File.join(directory, 'config.json'),
          capacity_receipt: File.join(directory, 'capacity.json'), selection: campaign.selection)
      end
      refute(File.exist?(campaign.root))
      File.write(campaign.selection['metadata'], JSON.generate(campaign.source))
      File.write(File.join(campaign.selection['runtime'], 'bin/vpsfree-kb-devcluster'), 'wrong fixed metadata')
      assert_raises(KbVerify::Error) do
        KbVerify::Campaign.new(root: campaign.root, config: File.join(directory, 'config.json'),
          capacity_receipt: File.join(directory, 'capacity.json'), selection: campaign.selection)
      end
      refute(File.exist?(campaign.root))
    end
  end

  def test_failed_optional_layout_cannot_be_crossed_into_runtime_or_capture
    with_campaign do |campaign|
      calls = []
      campaign.define_singleton_method(:installed_layout) { calls << :layout; raise KbVerify::Error, 'synthetic layout failure' }
      campaign.define_singleton_method(:runtime_smoke) { flunk('failed campaign reached public start') }
      assert_raises(KbVerify::Error) { campaign.run('installed-layout') }
      before = File.binread(campaign.file('receipts/installed-layout-attempt.json'))
      assert_raises(KbVerify::Error) { campaign.run('runtime-smoke') }
      assert_raises(Errno::ENOENT) { campaign.run('bilingual-capture') }
      assert_equal([:layout], calls)
      assert_equal(before, File.binread(campaign.file('receipts/installed-layout-attempt.json')))
      refute(File.exist?(campaign.file('receipts/runtime-smoke-attempt.json')))
      refute(File.exist?(campaign.file('state')))
    end
  end

  def test_missing_or_wrong_identity_capacity_receipt_precedes_root_creation_and_commands
    %w[missing kind source selection configuration configuration_sha256 root capacity_receipt].each do |wrong|
      with_campaign do |campaign|
        value = assessment(campaign)
        if wrong == 'missing'
          File.unlink(File.join(File.dirname(campaign.root), 'capacity.json'))
        elsif wrong == 'kind'
          value['kind'] = 'historical-two-root'
          write_assessment(campaign, value)
        else
          value['bindings'] = Marshal.load(Marshal.dump(campaign.inputs))
          value['bindings'][wrong] = 'mismatch'
          write_assessment(campaign, value)
        end
        campaign.define_singleton_method(:command) { |*_args, **| flunk('invalid receipt reached command') }
        assert_raises(KbVerify::Error, Errno::ENOENT) { campaign.run('runtime-smoke') }
        refute(File.exist?(campaign.root))
      end
    end
  end

  def test_capture_refuses_old_or_changed_smoke_receipt_without_reinterpreting_it
    with_campaign do |campaign|
      campaign.initialize_campaign
      valid = { 'schema' => 1, 'kind' => KbVerify::KIND, 'phase' => 'runtime-smoke', 'complete' => true, 'inputs' => campaign.inputs }
      [valid.merge('kind' => 'historical-two-root'), valid.merge('complete' => false), valid.merge('inputs' => {})].each do |invalid|
        campaign.write('receipts/runtime-smoke.json', invalid)
        before = File.binread(campaign.file('receipts/runtime-smoke.json'))
        campaign.define_singleton_method(:command) { |*_args, **| flunk('rejected receipt reached capture') }
        assert_raises(KbVerify::Error) { campaign.run('bilingual-capture') }
        assert_equal(before, File.binread(campaign.file('receipts/runtime-smoke.json')))
        refute(File.exist?(campaign.file('receipts/bilingual-capture-attempt.json')))
      end
    end
  end

  def test_physical_campaign_lock_refuses_a_second_writer_before_phase_or_command
    with_campaign do |campaign|
      campaign.initialize_campaign
      File.open(campaign.file('verify.lock'), File::RDWR | File::CREAT, 0o600) do |holder|
        assert(holder.flock(File::LOCK_EX | File::LOCK_NB))
        campaign.define_singleton_method(:command) { |*_args, **| flunk('contending writer reached command') }
        error = assert_raises(KbVerify::Error) { campaign.run('runtime-smoke') }
        assert_equal('verification campaign is already running', error.message)
        refute(File.exist?(campaign.file('receipts/runtime-smoke-attempt.json')))
      end
    end
  end

  def test_installed_layout_is_reusable_and_not_a_smoke_prerequisite
    with_campaign do |campaign|
      calls = []
      campaign.define_singleton_method(:installed_layout) { calls << :layout }
      campaign.run('installed-layout')
      before = File.binread(campaign.file('receipts/installed-layout.json'))
      campaign.run('installed-layout')
      assert_equal([:layout], calls)
      assert_equal(before, File.binread(campaign.file('receipts/installed-layout.json')))
    end
    with_campaign do |campaign|
      campaign.define_singleton_method(:runtime_smoke) { check(true, 'synthetic phase dispatch') }
      campaign.run('runtime-smoke')
      assert(campaign.read('receipts/runtime-smoke.json')['complete'])
      refute(File.exist?(campaign.file('receipts/installed-layout.json')))
    end
    with_campaign do |campaign|
      campaign.define_singleton_method(:command) { |*_args, **| flunk('missing smoke prerequisite reached command') }
      assert_raises(Errno::ENOENT) { campaign.run('bilingual-capture') }
      refute(File.exist?(campaign.file('receipts/bilingual-capture-attempt.json')))
    end
  end

  def test_installed_layout_does_not_construct_packages_or_initialize_runtime
    with_campaign do |campaign|
      calls = []
      campaign.define_singleton_method(:command) do |*argv, **|
        calls << argv
        case argv.first
        when 'git' then ['', 128]
        when /vpsfree-kb-devcluster/ then ['{"found":false}', 0]
        when /vpsfree-kb-capture/
          unless argv.include?('--help')
            target = argv.include?('--output-root') ? file('output') : file('work')
            FileUtils.mkdir_p(File.join(target, 'tmp'))
          end
          ['', argv.include?('--help') ? 0 : 1]
        else flunk("unexpected command #{argv}")
        end
      end
      campaign.run('installed-layout')
      refute(calls.any? { |argv| argv.first == 'nix' })
      refute(File.exist?(campaign.file('state')))
      assert_equal(1, calls.count { |argv| argv.include?('status') })
      assert_empty(Dir.glob(campaign.file('predecessor*')))
    end
  end

  def descriptor(campaign, run = 'first-run')
    { 'instance_id' => 'same-instance', 'run_id' => run, 'artifact_id' => 'same-artifact', 'artifact_sha256' => 'a' * 64,
      'machines' => { 'services' => {}, 'node1' => {} },
      'provenance' => { 'source' => campaign.source, 'guest_identity' => { 'schema' => 1, 'artifact_id' => 'same-artifact' },
        'machine_toplevels' => { 'services' => '/nix/store/same-services', 'node1' => '/nix/store/same-node' } } }
  end

  def smoke_sequence(fail_at: nil, incomplete: false)
    with_campaign do |campaign|
      calls = []
      first = descriptor(campaign)
      resumed = descriptor(campaign, 'second-run')
      descriptor_queue = [first, resumed]
      identity = { 'credentials' => KbVerify::CREDENTIALS.to_h { |name| [name, "digest-#{name}"] },
        'accounts_sha256' => 'accounts-digest', 'disks' => 'same-disks', 'artifacts' => 'same-artifact', 'images' => 'same-image' }
      sentinel = { 'services' => 'root-digest', 'node1' => 'data-digest' }
      campaign.define_singleton_method(:descriptor) { descriptor_queue.shift || raise('unexpected extra descriptor') }
      campaign.define_singleton_method(:capacity) { |operation| calls << ['capacity', operation] }
      campaign.define_singleton_method(:resources) { |value, **| calls << ['resources', value['run_id']] }
      campaign.define_singleton_method(:read_smoke) { |path| calls << ['read-smoke', path] }
      campaign.define_singleton_method(:identities) { identity }
      campaign.define_singleton_method(:sentinels) { sentinel }
      campaign.define_singleton_method(:command) do |*argv, **options|
        calls << argv
        action = argv[3] if argv.first.end_with?('/bin/vpsfree-kb-devcluster')
        raise KbVerify::Error, "synthetic native #{action} failure" if action && action == fail_at
        if action == 'start'
          FileUtils.mkdir_p(file('state/clusters/same-slug'), mode: 0o700)
          write('state/clusters/same-slug/processes-first-run.json', first.slice('instance_id', 'run_id', 'artifact_id', 'artifact_sha256').merge('schema' => 1, 'complete' => !incomplete))
        end
        [action == 'status' ? JSON.generate('found' => true, 'state' => 'stopped', 'ready' => false) : '', 0]
      end
      if fail_at || incomplete
        assert_raises(KbVerify::Error) { campaign.run('runtime-smoke') }
        refute(File.exist?(campaign.file('receipts/runtime-smoke.json')))
        refute(calls.any? { |argv| argv[3] == 'resume' })
        before = calls.dup
        assert_raises(KbVerify::Error) { campaign.run('runtime-smoke') }
        assert_equal(before, calls)
        assert_equal('failed', campaign.read('receipts/runtime-smoke-attempt.json')['stage'])
        return
      end
      campaign.run('runtime-smoke')
      commands = calls.select { |argv| argv.first.end_with?('/bin/vpsfree-kb-devcluster') }
      assert_equal(%w[start ssh ssh stop status resume], commands.map { |argv| argv[3] })
      assert(commands.all? { |argv| argv[0] == File.join(campaign.selection['runtime'], 'bin/vpsfree-kb-devcluster') && argv[2] == campaign.file('state') })
      assert_equal(%w[start resume], calls.select { |argv| argv.first == 'capacity' }.map { |argv| argv[1] })
      %w[start stop resume].each do |action|
        assert_equal(['--timeout', '900'], commands.find { |argv| argv[3] == action }[5, 2])
      end
      assert_equal(['--network', 'local', '--topology', 'single', '--config', campaign.file('config.json')], commands.first[7..])
      assert(calls.any? { |argv| argv[1].is_a?(String) && argv[1].end_with?('/tools/verify-live-lease.cjs') && argv[2..] ==
        [campaign.file('smoke-connection.json'), campaign.selection['metadata'], campaign.selection['runtime'], campaign.file('state'), campaign.file('config.json')] })
      refute(commands.any? { |argv| %w[update reset].include?(argv[3]) })
      refute(calls.any? { |argv| argv.include?('nix') || argv.join.include?('console-router') || argv.join.include?('state-b') })
      assert_equal(first, campaign.read('smoke-connection.json'))
      assert_equal(resumed, campaign.read('accepted-runtime.json'))
      assert_equal({ 'identities' => identity, 'sentinels' => sentinel }, campaign.read('continuity.json'))
      receipt = campaign.read('receipts/runtime-smoke.json')
      assert_equal(KbVerify::KIND, receipt['kind'])
      assert(receipt['complete'])
      assert_includes(receipt['assertions'], 'cold resume does not rebuild closures')
      assert_empty(descriptor_queue)
      assert_raises(KbVerify::Error) { campaign.run('runtime-smoke') }
    end
  end

  def test_final_source_smoke_start_lease_stop_resume_preserves_continuity_without_historical_mutations
    smoke_sequence
  end

  def test_native_start_stop_and_incomplete_exit_end_phase_without_resume_or_replay
    smoke_sequence(fail_at: 'start')
    smoke_sequence(fail_at: 'stop')
    smoke_sequence(incomplete: true)
  end

  def test_descriptor_rechecks_each_actual_guest_identity_closure_and_selected_source
    with_campaign do |campaign|
      value = descriptor(campaign)
      calls = []
      campaign.define_singleton_method(:engine) do |action, *args, **|
        calls << [action, *args]
        result = action == 'connection' ? JSON.generate(value) : args[2] == 'cat' ? JSON.generate(value.dig('provenance', 'guest_identity')) : value.dig('provenance', 'machine_toplevels', args.first) + "\n"
        [result, 0]
      end
      assert_equal(value, campaign.descriptor)
      assert_equal(%w[connection ssh ssh ssh ssh], calls.map(&:first))
      assert_equal(%w[services node1], calls.select { |call| call[3] == 'cat' }.map { |call| call[1] })
      value['provenance']['source'] = value['provenance']['source'].merge('revision' => 'b' * 40)
      before = calls.length
      assert_raises(KbVerify::Error) { campaign.descriptor }
      assert_equal(before + 1, calls.length, 'wrong source must refuse before SSH')
    end
  end

  def test_continuity_refuses_changed_run_artifact_closure_credential_account_disk_and_sentinel
    with_campaign do |campaign|
      before = descriptor(campaign)
      after = descriptor(campaign, 'second-run')
      identity = { 'credentials' => 'same-six', 'accounts_sha256' => 'same-accounts', 'disks' => 'same-disks', 'images' => 'same-image' }
      sentinel = { 'services' => 'same-root', 'node1' => 'same-data' }
      campaign.define_singleton_method(:identities) { identity }
      campaign.define_singleton_method(:sentinels) { sentinel }
      campaign.continuity(before, after, identity.dup, sentinel.dup)
      [after.merge('run_id' => before['run_id']), after.merge('instance_id' => 'different'), after.merge('artifact_id' => 'different'),
        after.merge('provenance' => after['provenance'].merge('machine_toplevels' => {}))].each do |invalid|
        assert_raises(KbVerify::Error) { campaign.continuity(before, invalid, identity.dup, sentinel.dup) }
      end
      %w[credentials accounts_sha256 disks images].each do |key|
        assert_raises(KbVerify::Error) { campaign.continuity(before, after, identity.merge(key => 'different'), sentinel.dup) }
      end
      assert_raises(KbVerify::Error) { campaign.continuity(before, after, identity.dup, { 'services' => 'changed' }) }
    end
  end

  def test_six_private_credentials_accounts_and_sparse_disk_identity_are_read_from_one_state
    with_campaign do |campaign|
      campaign.initialize_campaign
      directory = campaign.file('state/clusters/same-slug')
      FileUtils.mkdir_p(File.join(directory, 'credentials'), mode: 0o700)
      FileUtils.mkdir_p(File.join(directory, 'disks'), mode: 0o700)
      KbVerify::CREDENTIALS.each { |name| File.write(File.join(directory, 'credentials', name), name, perm: 0o600) }
      %w[services-root.img node1-tank.img].each do |name|
        File.open(File.join(directory, 'disks', name), 'w', 0o600) { |stream| stream.truncate(8 * KbVerify::GIB) }
      end
      accounts = File.join(directory, 'accounts.json')
      File.write(accounts, JSON.generate('users' => campaign.config.fetch('seed').fetch('users')), perm: 0o600)
      campaign.write('state/clusters/same-slug/artifact-one.json', { 'artifact_id' => 'same-artifact' })
      image = File.join(directory, 'image.img')
      File.open(image, 'w', 0o600) { |stream| stream.truncate(8 * KbVerify::GIB) }
      campaign.define_singleton_method(:image_paths) { [image, image] }
      before = campaign.identities
      assert_equal(Digest::SHA256.file(accounts).hexdigest, before['accounts_sha256'])
      assert_equal(KbVerify::CREDENTIALS.sort, before['credentials'].keys.sort)
      assert_equal(1, before['images'].length)
      assert_equal(2, before['disks'].length)
      File.write(accounts, JSON.generate('users' => []), perm: 0o600)
      refute_equal(before['accounts_sha256'], campaign.identities['accounts_sha256'])
    end
  end

  def test_read_smoke_uses_real_selected_connection_tls_accounts_and_member_browser_helpers
    with_campaign do |campaign|
      campaign.initialize_campaign
      value = { 'member' => { 'id' => 2, 'login' => 'test-user1' }, 'api_tls_verified' => true, 'php_member_read' => true }
      calls = []
      campaign.define_singleton_method(:command) { |*argv, **| calls << argv; [JSON.generate(value), 0] }
      campaign.read_smoke(campaign.file('connection.json'))
      assert_equal(['node', '-e'], calls.first[0, 2])
      assert_equal([campaign.file('connection.json'), campaign.selection['metadata'], campaign.source['source']], calls.first.last(3))
      script = calls.first[2]
      %w[readConnection openLease connection.verify inventoryIdentity launchBrowser login assertInventoryMember lease.assertLive].each { |name| assert_includes(script, name) }
      assert_includes(script, "goto(page, '/?page=adminvps&action=list')")
      assert_equal(value, campaign.read('receipts/read-smoke.json'))
      value['member']['login'] = 'test-admin'
      assert_raises(KbVerify::Error) { campaign.read_smoke(campaign.file('connection.json')) }
    end
  end

  def resource_transport(campaign, services_bytes: 2 * KbVerify::GIB, tank_bytes: 6 * KbVerify::GIB)
    campaign.define_singleton_method(:engine) do |action, machine, *args, **options|
      raise 'resource observation must use public SSH' unless action == 'ssh' && args == ['--', 'sh', '-s']
      raise 'missing real memory observation' unless options.fetch(:input).include?('/proc/meminfo')
      memory = "available_memory_bytes=#{512 * 1024**2}\n"
      pressure = "some avg10=0.00 avg60=1.23 avg300=0.01 total=12345\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=25\n"
      [memory + pressure + (machine == 'services' ? "available_bytes=#{services_bytes}\navailable_inodes=1200\n" : "tank_available_bytes=#{tank_bytes}\n"), 0]
    end
  end

  def test_private_resource_receipt_retains_native_some_and_full_pressure_and_allocations
    with_campaign do |campaign|
      campaign.initialize_campaign
      resource_transport(campaign)
      campaign.resources(descriptor(campaign), capture: true)
      receipt = campaign.read(Dir.glob(campaign.file('receipts/resources-*.json')).fetch(0).delete_prefix("#{campaign.root}/"))
      assert_equal(KbVerify::KIND, receipt['kind'])
      assert(receipt['capture_admitted'])
      %w[services node1].each do |machine|
        pressure = receipt.dig('observations', machine, 'pressure')
        assert_equal("some avg10=0.00 avg60=1.23 avg300=0.01 total=12345\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=25\n", pressure)
        refute_includes(pressure, 'available_memory_bytes=')
      end
      assert_equal(16 * KbVerify::GIB, receipt.dig('output_allocations', 'disk_bytes'))
      assert_equal(0o600, File.stat(Dir.glob(campaign.file('receipts/resources-*.json')).fetch(0)).mode & 0o777)
    end
  end

  def test_insufficient_live_bytes_inodes_guest_memory_and_quota_headroom_refuse_capture
    with_campaign do |campaign|
      campaign.initialize_campaign
      resource_transport(campaign, services_bytes: KbVerify::GIB - 1)
      assert_raises(KbVerify::Error) { campaign.resources(descriptor(campaign)) }
      assert_empty(Dir.glob(campaign.file('receipts/resources-*.json')))
      resource_transport(campaign, tank_bytes: 5 * KbVerify::GIB - 1)
      assert_raises(KbVerify::Error) { campaign.resources(descriptor(campaign), capture: true) }
      %w[minimum_free_inodes services_memory_bytes node_memory_bytes].each do |key|
        resource_transport(campaign)
        value = assessment(campaign)
        value['capture_assessment'][key] = key == 'minimum_free_inodes' ? 1201 : 512 * 1024**2 + 1
        write_assessment(campaign, value)
        assert_raises(KbVerify::Error) { campaign.resources(descriptor(campaign), capture: true) }
      end
      assert_empty(Dir.glob(campaign.file('receipts/resources-*.json')))
    end
  end

  def test_capture_uses_same_resumed_instance_both_languages_selectors_cwd_strict_validation_and_export
    with_campaign do |campaign|
      campaign.initialize_campaign
      current = descriptor(campaign, 'resumed')
      identity, sentinel = { 'same' => 'identity' }, { 'services' => 'same', 'node1' => 'same' }
      campaign.write('accepted-runtime.json', current)
      campaign.write('continuity.json', { 'identities' => identity, 'sentinels' => sentinel })
      campaign.define_singleton_method(:descriptor) { current }
      campaign.define_singleton_method(:identities) { identity }
      campaign.define_singleton_method(:sentinels) { sentinel }
      calls = []
      campaign.define_singleton_method(:capacity) { |operation| calls << ['capacity', operation] }
      campaign.define_singleton_method(:resources) { |value, **opts| calls << ['resources', value['run_id'], opts] }
      campaign.define_singleton_method(:command) do |*argv, **options|
        calls << [argv, options]
        if argv[3] == 'connection'
          [JSON.generate(current), 0]
        else
          FileUtils.mkdir_p(file('output/tmp'))
          rows = %w[cs en].map { |language| { 'language' => language, 'id' => 'networking/ip-address-list', 'provenance' => { 'source' => source } } }
          File.write(file('output/tmp/capture-results.json'), JSON.generate(rows))
          ['', 0]
        end
      end
      export = ->(output, destination) { calls << ['export', output, destination]; { 'sha256' => 'synthetic-export' } }
      campaign.instance_variable_set(:@phase, 'bilingual-capture')
      KbCaptureArtifacts.stub(:export, export) { campaign.bilingual_capture }
      captured = calls.select { |call| call[0].is_a?(Array) && call[0][0].end_with?('/bin/vpsfree-kb-capture') }
      assert_equal(3, captured.size)
      assert_includes(captured[0][0], '--cluster')
      assert_includes(captured[0][0], 'cs')
      assert_includes(captured[1][0], '--connection')
      assert_includes(captured[1][0], 'en')
      refute_includes(captured[2][0], '--output-root')
      assert_equal(campaign.file('output'), captured[2][1][:cwd])
      validations = calls.select { |call| call[0].is_a?(Array) && call[0][0].end_with?('/bin/vpsfree-kb-validate') }
      assert_equal(2, validations.size)
      assert_includes(validations[0][0], '--update')
      refute_includes(validations[1][0], '--update')
      refute(validations.any? { |call| call[0].include?('--allow-missing') })
      assert_operator(calls.index(['capacity', 'capture']), :<, calls.index(captured.first))
      assert_equal(['export', campaign.file('output'), campaign.file('export')], calls.last)
      assert_equal({ 'sha256' => 'synthetic-export' }, campaign.read('receipts/export.json'))
    end
  end

  def capacity_receipt(campaign)
    campaign.read(Dir.glob(campaign.file('receipts/capacity-*.json')).max.delete_prefix("#{campaign.root}/"))
  end

  def test_shared_filesystem_closure_dedup_one_image_and_separate_intrinsic_envelope
    with_campaign do |campaign|
      campaign.initialize_campaign
      fake_measurements(campaign)
      value = assessment(campaign)
      missing = { 'path' => '/nix/store/synthetic-kb-missing-closure', 'kind' => 'closure', 'nar_size' => 2 * KbVerify::GIB, 'download_size' => nil }
      image = { 'path' => '/nix/store/synthetic-kb-missing-image', 'kind' => 'service-image', 'nar_size' => 8 * KbVerify::GIB }
      value['missing_paths'] = [missing, missing.dup, image]
      write_assessment(campaign, value)
      campaign.capacity('start')
      receipt = capacity_receipt(campaign)
      assert_equal(1, receipt['filesystems'].size)
      assert_equal(26 * KbVerify::GIB, receipt['filesystems'][0]['remaining_growth_bytes'])
      assert_equal(24 * KbVerify::GIB, receipt['intrinsic_output_envelope_bytes'])
      assert_equal(16 * KbVerify::GIB, receipt['filesystems'][0]['reserve_bytes'])
      assert_equal(3 * KbVerify::GIB, receipt['filesystems'][0]['retained_growth_bytes'])
      assert_equal(KbVerify::GIB, receipt['filesystems'][0]['construction_overlap_bytes'])
      assert_equal(2, receipt['known_missing_paths'].size)
      assert_equal('unknown', receipt['scratch_bound'])
      assert_equal(Digest::SHA256.file(File.join(File.dirname(campaign.root), 'capacity.json')).hexdigest, receipt['receipt_sha256'])
      value['missing_paths'] << image.merge('path' => '/nix/store/second-image')
      write_assessment(campaign, value)
      assert_raises(KbVerify::Error) { campaign.capacity('start') }
    end
  end

  def test_actual_filesystem_binding_fresh_space_retained_growth_and_unknown_scratch_cannot_be_waived
    with_campaign do |campaign|
      campaign.initialize_campaign
      fake_measurements(campaign)
      value = assessment(campaign)
      value['roles']['store']['device'] = 20
      write_assessment(campaign, value)
      assert_raises(KbVerify::Error) { campaign.capacity('start') }
      write_assessment(campaign, assessment(campaign))
      # 24 GiB intrinsic + 16 reserve + 3 retained + 4 headroom + 1 overlap.
      fake_measurements(campaign, available: 48 * KbVerify::GIB - 1)
      assert_raises(KbVerify::Error) { campaign.capacity('start') }
      fake_measurements(campaign, available: 48 * KbVerify::GIB)
      campaign.capacity('start')
      value = assessment(campaign)
      value['build_plan']['scratch_bound'] = 8 * KbVerify::GIB
      write_assessment(campaign, value)
      assert_raises(KbVerify::Error) { campaign.capacity_assessment }
    end
  end

  def test_positive_ram_and_shm_margins_use_sequential_phase_peak_not_sum
    with_campaign do |campaign|
      value = assessment(campaign)
      requirements = campaign.memory_requirements(value, 'start')
      assert_equal(4 * KbVerify::GIB, requirements['guest_bytes'])
      assert_equal(2 * KbVerify::GIB, requirements['builder_bytes'])
      assert_equal(6 * KbVerify::GIB, requirements['ram_bytes'])
      assert_equal(5 * KbVerify::GIB, requirements['shm_bytes'])
      value['resource_overheads']['construction']['ram_bytes'] = 5 * KbVerify::GIB
      assert_equal(7 * KbVerify::GIB, campaign.memory_requirements(value, 'start')['ram_bytes'])
      assert_equal(6 * KbVerify::GIB, campaign.memory_requirements(value, 'resume')['ram_bytes'])
      %w[construction runtime_browser].product(%w[ram_bytes shm_bytes]).each do |phase, resource|
        invalid = assessment(campaign)
        invalid['resource_overheads'][phase][resource] = 0
        assert_raises(KbVerify::Error) { campaign.memory_requirements(invalid, 'start') }
      end
    end
  end

  def test_fresh_ram_and_shm_are_checked_before_each_start_and_resume
    with_campaign do |campaign|
      campaign.initialize_campaign
      fake_measurements(campaign)
      [%w[start ram_available], %w[resume shm_available]].each do |action, resource|
        campaign.define_singleton_method(:host_capacity) do
          { 'ram_available' => 6 * KbVerify::GIB, 'shm_available' => 5 * KbVerify::GIB }.merge(resource => (resource == 'ram_available' ? 6 : 5) * KbVerify::GIB - 1)
        end
        calls = []
        campaign.define_singleton_method(:command) { |*argv, **| calls << argv; ['', 0] }
        assert_raises(KbVerify::Error) { campaign.engine(action) }
        assert_empty(calls)
      end
    end
  end

  def test_live_capture_checks_incremental_margins_without_readmitting_resident_guests
    with_campaign do |campaign|
      campaign.initialize_campaign
      fake_measurements(campaign)
      available = { 'ram_available' => 6 * KbVerify::GIB, 'shm_available' => 5 * KbVerify::GIB }
      campaign.define_singleton_method(:host_capacity) { available.dup }
      campaign.capacity('start')
      admitted = capacity_receipt(campaign)
      assert_equal(6 * KbVerify::GIB, admitted.dig('memory_requirements', 'ram_bytes'))
      assert_equal(5 * KbVerify::GIB, admitted.dig('memory_requirements', 'shm_bytes'))

      # Fresh availability already excludes the 4 GiB of admitted running guests.
      available.transform_values! { |bytes| bytes - 4 * KbVerify::GIB }
      previous = Dir.glob(campaign.file('receipts/capacity-*.json'))
      campaign.capacity('capture')
      paths = Dir.glob(campaign.file('receipts/capacity-*.json'))
      created = paths - previous
      assert_equal(1, created.size)
      receipt = campaign.read(created.fetch(0).delete_prefix("#{campaign.root}/"))
      assert_equal('capture', receipt['operation'])
      assert_equal(available, receipt['host'])
      assert_equal(4 * KbVerify::GIB, receipt.dig('memory_requirements', 'guest_bytes'))
      assert_equal(2 * KbVerify::GIB, receipt.dig('memory_requirements', 'ram_bytes'))
      assert_equal(KbVerify::GIB, receipt.dig('memory_requirements', 'shm_bytes'))
      assert_equal(assessment(campaign)['roles'], receipt.dig('assessment', 'roles'))
      assert_equal(Digest::SHA256.file(File.join(File.dirname(campaign.root), 'capacity.json')).hexdigest, receipt['receipt_sha256'])
      assert_equal(1, receipt['filesystems'].size)
      assert_equal(24 * KbVerify::GIB, receipt['filesystems'][0]['remaining_growth_bytes'])
      assert_equal(16 * KbVerify::GIB, receipt['filesystems'][0]['reserve_bytes'])
      assert_equal(3 * KbVerify::GIB, receipt['filesystems'][0]['retained_growth_bytes'])
      assert_equal('unknown', receipt['scratch_bound'])

      %w[start resume].each do |operation|
        error = assert_raises(KbVerify::Error) { campaign.capacity(operation) }
        assert_includes(error.message, 'fresh host RAM')
      end
      %w[ram_available shm_available].each do |resource|
        margin = available.fetch(resource)
        available[resource] = margin - 1
        error = assert_raises(KbVerify::Error) { campaign.capacity('capture') }
        assert_includes(error.message, resource == 'ram_available' ? 'fresh host RAM' : 'fresh shared memory')
        available[resource] = margin
      end
      assert_equal(paths.sort, Dir.glob(campaign.file('receipts/capacity-*.json')).sort)
    end
  end

  def test_sparse_future_growth_physical_inode_dedup_and_resume_do_not_add_an_image
    with_campaign do |campaign|
      campaign.initialize_campaign
      directory = campaign.file('state/clusters/same-slug/disks')
      FileUtils.mkdir_p(directory, mode: 0o700)
      disk = File.join(directory, 'node1-tank.img')
      File.open(disk, 'w', 0o600) { |stream| stream.truncate(8 * KbVerify::GIB); stream.seek(0); stream.write('sentinel') }
      original = File.stat(disk)
      before = campaign.remaining_growth
      assert_equal(8 * KbVerify::GIB, original.size)
      assert_equal(16 * KbVerify::GIB - original.blocks * 512, before['disk_bytes'])
      assert_operator(before['disk_bytes'], :>, 8 * KbVerify::GIB)
      File.link(disk, File.join(directory, 'services-root.img'))
      aliased = campaign.remaining_growth
      assert_equal(1, aliased['retained_disks'].size)
      assert_equal(before['disk_bytes'], aliased['disk_bytes'], 'same allocated inode must be deducted once')
      image = '/nix/store/synthetic-one-service-image'
      campaign.define_singleton_method(:image_paths) { [image, image] }
      allocation = campaign.method(:allocation)
      campaign.define_singleton_method(:allocation) do |path|
        path == image ? { 'path' => path, 'device' => 20, 'inode' => 41, 'allocated_bytes' => 8 * KbVerify::GIB, 'apparent_bytes' => 8 * KbVerify::GIB } : allocation.call(path)
      end
      after = campaign.remaining_growth
      assert_equal(0, after['image_bytes'])
      assert_equal(1, after['realized_images'].size)
      assert_equal(aliased['disk_bytes'], after['disk_bytes'])
    end
  end

  def test_public_nix_projection_has_two_2048_runtime_guests_and_actual_2048_image_builder_with_unchanged_kernels
    Dir.mktmpdir do |directory|
      reduced = configuration
      normal = Marshal.load(Marshal.dump(reduced))
      normal['services']['memoryMiB'] = 4096
      normal['nodes']['node1']['memoryMiB'] = 4096
      source = File.expand_path('..', __dir__)
      reference = "git+file://#{source}"
      environment = ENV.keys.grep(/\AVPSADMIN_(?:DEVCLUSTER|KB)_/).to_h { |name| [name, nil] }
      environment.merge!('VPSADMINOS_CONFIG' => nil, 'VPSADMIN_DEVCLUSTER_NETWORK' => 'local', 'VPSADMIN_DEVCLUSTER_TOPOLOGY' => 'single',
        'VPSADMIN_DEVCLUSTER_TELEGRAM_ENABLE' => '0')
      expression = <<~NIX
        let
          plan = (builtins.getFlake #{JSON.generate(reference)}).runtimePlan;
          imageContext = builtins.getContext plan.machines.services.diskImage;
        in {
          machines = builtins.mapAttrs (_: machine: {
            inherit (machine) memory kernel cpus;
            disks = machine.disks;
          }) plan.machines;
          imageDerivations = builtins.filter (name: builtins.match ".*[.]drv" name != null) (builtins.attrNames imageContext);
        }
      NIX
      project = lambda do |name, config|
        input = File.join(directory, "#{name}.json")
        File.write(input, JSON.generate(config), perm: 0o600)
        output, error, status = Open3.capture3(environment.merge('VPSADMIN_DEVCLUSTER_CONFIG_FILE' => input),
          'nix', 'eval', '--impure', '--json', '--expr', expression, chdir: source)
        assert(status.success?, "public runtimePlan projection refused: #{error}")
        JSON.parse(output)
      end
      value = project.call('reduced', reduced)
      baseline = project.call('baseline', normal)
      assert_equal(%w[node1 services], value['machines'].keys.sort)
      assert_equal([2048, 2048], value['machines'].values.map { |machine| machine['memory'] })
      assert_equal([4, 4], value['machines'].values.map { |machine| machine['cpus'] })
      assert_equal(baseline['machines'].transform_values { |machine| machine['kernel'] }, value['machines'].transform_values { |machine| machine['kernel'] })
      value['machines'].each_value { |machine| assert_match(%r{\A/nix/store/[a-z0-9]{32}-.+/bzImage\z}, machine['kernel']) }
      assert_equal('8G', value.dig('machines', 'node1', 'disks').first.fetch('size'))
      assert_equal(1, value['imageDerivations'].size)
      output, error, status = Open3.capture3('nix', 'derivation', 'show', value['imageDerivations'].first)
      assert(status.success?, "native image derivation inspection refused: #{error}")
      native = JSON.parse(output)
      assert_equal(4, native.fetch('version'))
      derivations = native.fetch('derivations')
      derivation_key = File.basename(value['imageDerivations'].first)
      assert_equal([derivation_key], derivations.keys)
      record = derivations.fetch(derivation_key)
      context = "selected image #{derivation_key}: keys=#{record.keys.sort.inspect}"
      assert(record.key?('structuredAttrs'), context)
      attributes = record.fetch('structuredAttrs')
      context += "; structured keys=#{attributes.keys.sort.inspect}"
      assert(attributes.key?('env'), context)
      builder_environment = attributes.fetch('env')
      context += "; structured env keys=#{builder_environment.keys.sort.inspect}"
      assert(builder_environment.key?('QEMU_OPTS'), context)
      tokens = Shellwords.split(builder_environment.fetch('QEMU_OPTS'))
      option_values = lambda do |flag|
        tokens.each_cons(2).filter_map { |option, value| value if option == flag }
      end
      sizes = option_values.call('-m')
      objects = option_values.call('-object').select { |value| value.start_with?('memory-backend-') }
      backends = option_values.call('-machine').flat_map { |value| value.split(',').grep(/\Amemory-backend=/) }
      context += "; memory=#{sizes.inspect}; memory objects=#{objects.inspect}; memory backends=#{backends.inspect}"
      assert_equal(['2048'], sizes, context)
      assert_equal(['memory-backend-memfd,id=mem,size=2048M,share=on'], objects, context)
      assert_equal(['memory-backend=mem'], backends, context)
    end
  end

  def test_selected_tools_scrub_inherited_workspace_and_source_overrides
    with_campaign do |campaign|
      name = 'VPSADMIN_DEVCLUSTER_VPSADMIN_SOURCE'
      previous = ENV[name]
      ENV[name] = '/wrong/source'
      environment = KbVerify::Commands.new(campaign.selection, campaign.root).environment
      refute(environment.key?(name))
      refute(environment.key?('DEV_SESSION_SLUG'))
      refute(environment.key?('RUBYOPT'))
      assert_equal(campaign.selection['path'], environment['PATH'])
      assert_equal(campaign.selection['browsers'], environment['PLAYWRIGHT_BROWSERS_PATH'])
      assert_equal(campaign.selection['gem_home'], environment['GEM_HOME'])
      assert_equal(environment['GEM_HOME'], environment['GEM_PATH'])
      assert_includes(environment['NIX_CONFIG'], "max-jobs = 1\n")
      assert_includes(environment['NIX_CONFIG'], "cores = 1\n")
    ensure
      ENV[name] = previous
    end
  end

  def test_failed_native_phase_keeps_private_stdout_stderr_exact_exit_and_stage_without_replay
    with_campaign do |campaign|
      argv = [RbConfig.ruby, '-e', 'STDOUT.write("native output"); STDERR.write("native error"); exit 23']
      campaign.define_singleton_method(:installed_layout) do
        checkpoint('synthetic-construction')
        command(*argv)
      end
      failure = nil
      stdout, stderr = capture_io do
        failure = assert_raises(KbVerify::Error) do
          campaign.run('installed-layout')
        end
      end
      assert_equal('', stdout)
      assert_equal('', stderr)
      path = Dir.glob(campaign.file('diagnostics/*/command.json')).fetch(0)
      assert_includes(failure.message, path)
      record = JSON.parse(File.read(path))
      assert_equal(argv, record['argv'])
      assert_equal(23, record['exit_code'])
      assert_nil(record['signal'])
      assert(record['complete'])
      refute(record['accepted'])
      assert_equal('installed-layout/synthetic-construction', record['stage'])
      assert_equal('native output', File.read(File.join(File.dirname(path), 'stdout')))
      assert_equal('native error', File.read(File.join(File.dirname(path), 'stderr')))
      Dir.glob(File.join(File.dirname(path), '*')).each { |name| assert_equal(0o600, File.stat(name).mode & 0o777) }
      refute(record.key?('environment'))
      attempt = campaign.read('receipts/installed-layout-attempt.json')
      assert_equal('failed', attempt['stage'])
      assert_equal(campaign.inputs, attempt['inputs'])
      assert_equal('KbVerify::Error', attempt['error_class'])
      refute(attempt['complete'])
      refute(File.exist?(campaign.file('receipts/installed-layout.json')))
      before = File.binread(campaign.file('receipts/installed-layout-attempt.json'))
      replay = assert_raises(KbVerify::Error) { campaign.run('installed-layout') }
      assert_equal('incomplete phase requires diagnosis; no automatic campaign replay', replay.message)
      assert_raises(Errno::ENOENT) { campaign.run('bilingual-capture') }
      refute(File.exist?(campaign.file('receipts/bilingual-capture-attempt.json')))
      assert_equal(before, File.binread(campaign.file('receipts/installed-layout-attempt.json')))
      assert_equal([path], Dir.glob(campaign.file('diagnostics/*/command.json')))
      refute(File.exist?(campaign.file('state-a')))
      refute(File.exist?(campaign.file('state-b')))
    end
  end

  def test_interruption_reaps_only_spawned_public_command_and_retains_native_signal_evidence
    with_campaign do |campaign|
      campaign.initialize_campaign
      marker = campaign.file('work/child-ready')
      argv = [RbConfig.ruby, '-e', 'File.write(ARGV[0], Process.pid.to_s); sleep 60', marker]
      owner = Thread.new do
        campaign.commands.call(argv, cwd: campaign.file('work'), stage: 'synthetic/interruption')
      rescue Interrupt
        :interrupted
      end
      Timeout.timeout(5) { sleep 0.01 until File.exist?(marker) }
      owner.raise(Interrupt)
      assert_equal(:interrupted, Timeout.timeout(15) { owner.value })
      record = JSON.parse(File.read(Dir.glob(campaign.file('diagnostics/*/command.json')).fetch(0)))
      assert(record['complete'])
      assert(record['interrupted'])
      assert_equal(Integer(File.read(marker)), record['pid'])
      assert_equal(Signal.list.fetch('TERM'), record['signal'])
      assert_equal('spawned public command only', record['cleanup_scope'])
    ensure
      owner&.raise(Interrupt) if owner&.alive?
      owner&.join
    end
  end

end
