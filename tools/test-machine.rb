# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../cluster/lib/kb_machine'
require_relative '../cluster/lib/kb_source'

class PreparedMachineTest < Minitest::Test
  def configuration(image, suffix)
    { 'spin' => 'nixos', 'qemu' => '/not-executed', 'virtiofsd' => '/not-executed',
      'memory' => 64, 'cpus' => 1, 'cpu' => { 'cores' => 1, 'threads' => 1, 'sockets' => 1 },
      'kernel' => "/candidate/#{suffix}/kernel", 'initrd' => "/candidate/#{suffix}/initrd", 'toplevel' => "/candidate/#{suffix}/system",
      'diskImage' => image, 'disks' => [{ 'device' => 'services-data.img', 'type' => 'file', 'size' => '1M' }],
      'networks' => [{ 'type' => 'socket', 'mcast' => { 'address' => '230.0.0.1', 'port' => 31001 } }] }
  end

  def with_machine
    Dir.mktmpdir('kb-machine-') do |directory|
      state = KbRuntime::State.new(File.join(directory, 'state'), 'driver-test')
      identity = state.transaction(create: true) { state.initialize_identity }
      disks = state.path('disks')
      sockets = state.path('sockets')
      state.private_directory(disks, create: true)
      state.private_directory(sockets, create: true)
      image = File.join(directory, 'initial.img')
      File.write(image, 'initial root sentinel')
      config = configuration(image, 'old')
      artifact = { 'instance_id' => identity['instance_id'], 'artifact_id' => SecureRandom.uuid,
        'layout' => KbRuntime::Software.layout('machines' => { 'services' => config }) }
      machine = KbRuntime::NixosMachine.new('services', OsVm::MachineConfig.from_config(config), disks, sockets).bind_preparation(state, artifact)
      begin
        yield state, artifact, machine, config, disks, sockets
      ensure
        machine.finalize
      end
    end
  end

  def test_exact_upstream_driver_keeps_root_and_data_but_boots_new_kernel_init_and_toplevel
    with_machine do |state, artifact, machine, config, disks, sockets|
      machine.send(:prepare_disks)
      root = File.join(disks, 'services-root.img')
      data = File.join(disks, 'services-data.img')
      initial = [root, data].to_h { |path| [path, File.stat(path).ino] }
      File.open(data, 'r+b') { |file| file.write('data sentinel') }
      proof = state.read(state.path('disks-services.json'))
      assert_equal(config['diskImage'], proof['initial_images']['root'])
      candidate_image = File.join(File.dirname(config['diskImage']), 'candidate.img')
      File.write(candidate_image, 'replacement would lose the sentinel')
      replacement = config.merge('kernel' => '/candidate/new/kernel', 'initrd' => '/candidate/new/initrd',
        'toplevel' => '/candidate/new/system', 'diskImage' => candidate_image)
      newer = artifact.merge('artifact_id' => SecureRandom.uuid)
      next_machine = KbRuntime::NixosMachine.new('services', OsVm::MachineConfig.from_config(replacement), disks, sockets).bind_preparation(state, newer)
      begin
        next_machine.send(:prepare_disks)
        assert_equal(initial, [root, data].to_h { |path| [path, File.stat(path).ino] })
        assert_equal('initial root sentinel', File.read(root))
        assert_equal('data sentinel', File.read(data, 13))
        command = next_machine.send(:qemu_command)
        assert_equal('/candidate/new/kernel', command[command.index('-kernel') + 1])
        assert_equal('/candidate/new/initrd', command[command.index('-initrd') + 1])
        assert_includes(command[command.index('-append') + 1], 'init=/candidate/new/system/init')
        assert_includes(command, "socket,id=net0,mcast=230.0.0.1:31001")
      ensure
        next_machine.finalize
      end
    end
  end

  def test_missing_retained_root_is_not_recreated
    with_machine do |_state, _artifact, machine, _config, disks, _sockets|
      machine.send(:prepare_disks)
      root = File.join(disks, 'services-root.img')
      File.unlink(root)
      assert_raises(Errno::ENOENT) { machine.send(:prepare_disks) }
      refute(File.exist?(root))
    end
  end

  def test_unrecorded_root_is_not_adopted_or_replaced
    with_machine do |_state, _artifact, machine, _config, disks, _sockets|
      root = File.join(disks, 'services-root.img')
      File.write(root, 'foreign root')
      assert_raises(KbRuntime::Error) { machine.send(:prepare_disks) }
      assert_equal('foreign root', File.read(root))
    end
  end

  def test_explicit_multicast_port_survives_separate_osvm_processes
    program = <<~RUBY
      require 'json'
      require 'osvm'
      network = OsVm::MachineConfig::SocketNetwork.new(0, {
        'type' => 'socket', 'mcast' => { 'address' => '230.0.0.1', 'port' => Integer(ARGV.fetch(0)) }
      })
      puts JSON.generate(network.qemu_options)
    RUBY
    [31001, 31002].each do |port|
      out, err, status = Open3.capture3(RbConfig.ruby, '-e', program, port.to_s)
      assert(status.success?, err)
      assert_includes(JSON.parse(out), "socket,id=net0,mcast=230.0.0.1:#{port}")
    end
  end
end
