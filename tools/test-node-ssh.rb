# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
require 'shellwords'
require 'timeout'

class NodeSshTest < Minitest::Test
  NODE_KEY = '/tank/.vpsfree-kb-ssh/ssh_host_ed25519_key'
  ROOT_KEY = '/etc/ssh/ssh_host_ed25519_key'

  def projection
    return @@projection if defined?(@@projection)

    source = File.expand_path('..', __dir__)
    expression = <<~NIX
      let
        f = builtins.getFlake #{JSON.generate("git+file://#{source}")};
        inherit (f.inputs) vpsadmin vpsadminos vpsfStatus nixpkgs;
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          overlays = import (vpsadminos.outPath + "/os/overlays") {
            inherit (vpsadminos.inputs) netlinkrb ruby-lxc;
          };
        };
        test = (import (f.outPath + "/cluster/nix/test.nix") {
          inherit (pkgs) lib;
          inherit vpsadmin vpsadminos vpsfStatus;
          slug = "host-key-profile"; topology = "single"; networkMode = "local";
          bridgeHelper = ""; certDir = f.outPath + "/cluster";
          clusterConfigFile = builtins.toFile "ssh-profile.json" (builtins.toJSON {
            dns.enable = true;
            resolver = { mode = "upstream"; upstreamNameservers = [ "10.0.2.3" ]; };
          });
          sshPubKey = f.outPath + "/cluster/placeholder-authorized-key.pub";
          vpsadminSourcePath = vpsadmin.outPath;
          vpsadminosSourcePath = vpsadminos.outPath;
          haveapiSourcePath = ""; configSourcePath = "";
          notificationTemplatesSourcePath = ""; webSourcePath = "";
          vpsfStatusSourcePath = ""; vpsadminGoClientSourcePath = "";
          telegramEnable = "0"; telegramSecretsSourcePath = "";
        }) { inherit pkgs; };
        nixos = name: (import (nixpkgs.outPath + "/nixos/lib/eval-config.nix") {
          system = "x86_64-linux";
          specialArgs = { inherit vpsadminos; };
          modules = [
            (nixpkgs.outPath + "/nixos/modules/virtualisation/qemu-vm.nix")
            (vpsadminos.outPath + "/tests/configs/nixos/test-vm.nix")
            (vpsadminos.outPath + "/tests/configs/nixos/base.nix")
            test.machines.${name}.config
          ];
        }).config;
        services = nixos "services";
        dns = nixos "dns-primary";
        node = (import (vpsadminos.outPath + "/os") {
          configuration = null; pkgs = nixpkgs.outPath; system = "x86_64-linux";
          inherit (vpsadminos.inputs) netlinkrb ruby-lxc;
          extraArgs = { inherit vpsadminos; };
          modules = [
            (vpsadminos.outPath + "/tests/configs/vpsadminos/base.nix")
            test.machines.node1.config
          ];
        }).config;
        project = c: {
          hostKeys = c.services.openssh.hostKeys;
          sshdConfig = builtins.readFile c.environment.etc."ssh/sshd_config".source;
        };
      in {
        services = project services // {
          generation = services.systemd.services.sshd-keygen.script;
          after = services.systemd.services.sshd.after;
        };
        dns = project dns // {
          generation = dns.systemd.services.sshd-keygen.script;
          after = dns.systemd.services.sshd.after;
        };
        node = project node // {
          run = node.runit.services.sshd.run;
          poolOneShot = node.runit.services.pool-tank.oneShot;
          poolRun = node.runit.services.pool-tank.run;
        };
        tools = {
          findmnt = "${pkgs.util-linux}/bin/findmnt";
          zfs = "${pkgs.zfs}/bin/zfs";
          stat = "${pkgs.coreutils}/bin/stat";
          mkdir = "${pkgs.coreutils}/bin/mkdir";
          keygen = "${pkgs.openssh}/bin/ssh-keygen";
        };
      }
    NIX
    environment = ENV.keys.grep(/\AVPSADMIN_(?:DEVCLUSTER|KB)_/).to_h { |key| [key, nil] }
    environment['VPSADMINOS_CONFIG'] = nil
    output, error, status = Open3.capture3(environment, 'nix', 'eval', '--impure', '--json', '--expr', expression, chdir: source)
    assert(status.success?, "pinned SSH configuration projection refused: #{error}")
    @@projection = JSON.parse(output)
  end

  def test_actual_services_node_and_optional_dns_have_exactly_one_ed25519_declaration_and_hostkey_line
    %w[services node dns].each do |name|
      expected = name == 'node' ? NODE_KEY : ROOT_KEY
      value = projection.fetch(name)
      assert_equal([{ 'type' => 'ed25519', 'path' => expected }], value.fetch('hostKeys'), name)
      lines = value.fetch('sshdConfig').lines.filter_map { |line| line.strip if line.match?(/\A\s*HostKey\s/) }
      assert_equal(["HostKey #{expected}"], lines, name)
      unless name == 'node'
        refute_includes(value.fetch('sshdConfig'), '.vpsfree-kb-ssh')
        assert_includes(value.fetch('after'), 'sshd-keygen.service')
        refute(value.fetch('after').any? { |dependency| dependency.include?('pool-tank') })
        refute_includes(value.fetch('generation'), 'pool-tank')
        assert_equal(1, value.fetch('generation').scan(/^\s+-t "ed25519"/).length)
        assert_equal(1, value.fetch('generation').scan(/^\s+-f "#{Regexp.escape(ROOT_KEY)}"/).length)
      end
    end
    node = projection.fetch('node')
    assert_equal(true, node.fetch('poolOneShot'))
    assert_operator(node.fetch('poolRun').index('Mounting datasets'), :<, node.fetch('poolRun').index('Waiting for osctld'))
    run = node.fetch('run')
    assert_equal(1, run.scan(/^\s*waitForService pool-tank \|\| exit 1$/).length)
    assert_equal(1, run.scan(/^\s*# Ensure SSH host keys$/).length)
    daemon_exec = /^\s*exec \/nix\/store\/[^\s]+\/bin\/sshd -D -f \/etc\/ssh\/sshd_config$/
    assert_equal(1, run.scan(daemon_exec).length)
    assert_operator(run.index('waitForService pool-tank'), :<, run.index('# Ensure SSH host keys'))
    assert_operator(run.index('# Ensure SSH host keys'), :<, run.match(daemon_exec).begin(0))
    assert_operator(run.index('waitForService pool-tank'), :<, run.index('findmnt'))
    assert_operator(run.index('umask 077'), :<, run.index('# Ensure SSH host keys'))
    assert_equal(1, run.scan(/^\s+-t "ed25519"/).length)
    assert_equal(1, run.scan(/^\s+-f "#{Regexp.escape(NODE_KEY)}"/).length)
    assert_operator(run.index('# Ensure SSH host keys'), :<, run.index('/bin/sshd -D'))
  end

  def test_real_generation_and_second_start_preserve_private_bytes_and_public_fingerprint
    with_startup do |fixture|
      assert_start(fixture)
      key = fixture.fetch(:key)
      assert_equal(0o700, File.stat(File.dirname(key)).mode & 0o777)
      assert_equal(0o600, File.stat(key).mode & 0o777)
      assert_equal(0o600, File.stat("#{key}.pub").mode & 0o777)
      before = [File.stat(key).ino, Digest::SHA256.file(key).hexdigest, fingerprint(key)]
      assert_equal(%w[pool mount mounted mountpoint generate daemon], events(fixture))
      File.write(fixture.fetch(:events), '')
      assert_start(fixture)
      assert_equal(before, [File.stat(key).ino, Digest::SHA256.file(key).hexdigest, fingerprint(key)])
      assert_equal(%w[pool mount mounted mountpoint validate daemon], events(fixture))
    end
  end

  def test_pool_completion_barrier_prevents_generation_until_released
    with_startup do |fixture|
      with_child(fixture) do |pid, notification, release|
        assert_equal("pool\n", Timeout.timeout(5) { notification.gets })
        refute(File.exist?(fixture.fetch(:key)))
        assert_equal(['pool'], events(fixture))
        release.write("ready\n")
        release.close
        status = wait_child(fixture, pid)
        assert(status.success?, File.read(fixture.fetch(:error)))
        assert_equal(%w[pool mount mounted mountpoint generate daemon], events(fixture))
      end
    end
  end

  def test_unavailable_pool_refuses_before_any_storage_or_generation
    with_startup do |fixture|
      with_child(fixture) do |pid, notification, release|
        assert_equal("pool\n", Timeout.timeout(5) { notification.gets })
        release.close
        status = wait_child(fixture, pid)
        refute(status.success?)
        assert_equal(['pool'], events(fixture))
        refute(File.exist?(fixture.fetch(:key)))
      end
    end
  end

  def test_missing_tmpfs_wrong_dataset_mountpoint_and_unmounted_storage_refuse_before_generation
    [[:mount, ''], [:mount, 'tmpfs tmpfs /tank'], [:mount, 'foreign zfs /tank'],
      [:mount, 'tank zfs /elsewhere'], [:mounted, 'no'], [:mountpoint, '/elsewhere'],
      [:mount_exit, '23'], [:zfs_exit, '24'], [:stat_exit, '27']].each do |field, observation|
      with_startup do |fixture|
        fixture[field] = observation
        assert_refused(fixture)
      end
    end
  end

  def test_unsafe_tank_path_or_owner_mode_refuses_without_preparing_keys
    [:missing, :symlink, :file, :mode, :owner].each do |kind|
      with_startup do |fixture|
        tank = fixture.fetch(:tank)
        case kind
        when :missing then FileUtils.rmdir(tank)
        when :symlink
          FileUtils.rmdir(tank)
          File.symlink(File.dirname(tank), tank)
        when :file
          FileUtils.rmdir(tank)
          File.write(tank, 'unchanged')
        when :mode then File.chmod(0o777, tank)
        when :owner then fixture[:foreign] = tank
        end
        assert_refused(fixture)
      end
    end
  end

  def test_existing_unsafe_directory_and_failed_preparation_are_not_repaired
    [:symlink, :file, :mode, :owner, :mkdir].each do |kind|
      with_startup do |fixture|
        directory = File.dirname(fixture.fetch(:key))
        case kind
        when :symlink then File.symlink(fixture.fetch(:tank), directory)
        when :file then File.write(directory, 'unchanged')
        when :mode then Dir.mkdir(directory, 0o755)
        when :owner
          Dir.mkdir(directory, 0o700)
          fixture[:foreign] = directory
        when :mkdir then fixture[:mkdir_exit] = '25'
        end
        before = path_observation(directory) if kind != :mkdir
        assert_refused(fixture)
        assert_equal(before, path_observation(directory)) if before
      end
    end
  end

  def test_unsafe_private_key_type_mode_owner_link_or_invalid_material_is_preserved
    [:symlink, :directory, :mode, :owner, :hardlink, :invalid].each do |kind|
      with_startup do |fixture|
        assert_start(fixture)
        key = fixture.fetch(:key)
        case kind
        when :symlink
          File.unlink(key)
          File.symlink("#{key}.pub", key)
        when :directory
          File.unlink(key)
          Dir.mkdir(key, 0o700)
        when :mode then File.chmod(0o644, key)
        when :owner then fixture[:foreign] = key
        when :hardlink then File.link(key, "#{key}.retained")
        when :invalid then File.write(key, 'invalid private key')
        end
        before = path_observation(key)
        assert_refused(fixture)
        assert_equal(before, path_observation(key))
      end
    end
  end

  def test_unsafe_public_path_and_public_file_without_private_key_are_not_overwritten
    [:orphan, :symlink, :directory, :mode, :owner, :hardlink].each do |kind|
      with_startup do |fixture|
        assert_start(fixture)
        key = fixture.fetch(:key)
        public = "#{key}.pub"
        case kind
        when :orphan then File.unlink(key)
        when :symlink
          File.unlink(public)
          File.symlink(key, public)
        when :directory
          File.unlink(public)
          Dir.mkdir(public, 0o700)
        when :mode then File.chmod(0o666, public)
        when :owner then fixture[:foreign] = public
        when :hardlink then File.link(public, "#{public}.retained")
        end
        before = path_observation(public)
        assert_refused(fixture)
        assert_equal(before, path_observation(public))
      end
    end
  end

  def test_native_key_generation_failure_cannot_start_daemon_or_create_fallback
    with_startup do |fixture|
      fixture[:generate_exit] = '26'
      assert_refused(fixture, generation: true)
      assert_equal(%w[pool mount mounted mountpoint generate], events(fixture))
    end
  end

  private

  def executable(name)
    path = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |entry| File.join(entry, name) }.find { |entry| File.file?(entry) && File.executable?(entry) }
    raise "declared Nix shell is missing #{name}" unless path && File.realpath(path).start_with?('/nix/store/')
    path
  end

  def fingerprint(key)
    output, error, status = Open3.capture3(executable('ssh-keygen'), '-l', '-f', "#{key}.pub")
    assert(status.success?, error)
    assert_includes(output, '(ED25519)')
    output.split.fetch(1)
  end

  def events(fixture)
    File.read(fixture.fetch(:events)).lines.map(&:strip)
  end

  def path_observation(path)
    stat = File.lstat(path)
    content = if stat.file?
                Digest::SHA256.file(path).hexdigest
              elsif stat.symlink?
                File.readlink(path)
              end
    [stat.ino, stat.mode, stat.nlink, content]
  end

  def assert_start(fixture)
    _output, error, status = Open3.capture3(start_environment(fixture), executable('bash'), fixture.fetch(:script), 'ready')
    assert(status.success?, error)
  end

  def assert_refused(fixture, generation: false)
    File.write(fixture.fetch(:events), '')
    output, _error, status = Open3.capture3(start_environment(fixture), executable('bash'), fixture.fetch(:script), 'ready')
    refute(status.success?)
    assert_empty(output)
    refute_includes(events(fixture), 'daemon')
    refute_includes(events(fixture), 'generate') unless generation
    refute(File.exist?(File.join(fixture.fetch(:directory), 'etc/ssh/ssh_host_ed25519_key')))
  end

  def start_environment(fixture)
    { 'SSH_TEST_ROOT' => fixture.fetch(:directory), 'SSH_TEST_EVENTS' => fixture.fetch(:events),
      'SSH_TEST_MOUNT' => fixture.fetch(:mount, 'tank zfs /tank').gsub('/tank', fixture.fetch(:tank)),
      'SSH_TEST_MOUNTED' => fixture.fetch(:mounted, 'yes'),
      'SSH_TEST_MOUNTPOINT' => fixture.fetch(:mountpoint, '/tank').gsub('/tank', fixture.fetch(:tank)),
      'SSH_TEST_MOUNT_EXIT' => fixture.fetch(:mount_exit, '0'), 'SSH_TEST_ZFS_EXIT' => fixture.fetch(:zfs_exit, '0'),
      'SSH_TEST_STAT_EXIT' => fixture.fetch(:stat_exit, '0'),
      'SSH_TEST_FOREIGN' => fixture.fetch(:foreign, ''), 'SSH_TEST_MKDIR_EXIT' => fixture.fetch(:mkdir_exit, '0'),
      'SSH_TEST_GENERATE_EXIT' => fixture.fetch(:generate_exit, '0'),
      'PATH' => "#{fixture.fetch(:directory)}/bin:#{ENV.fetch('PATH')}" }
  end

  def with_startup
    Dir.mktmpdir('kb-node-ssh-', '/tmp') do |directory|
      File.chmod(0o700, directory)
      tank = File.join(directory, 'tank')
      Dir.mkdir(tank, 0o755)
      bin = File.join(directory, 'bin')
      Dir.mkdir(bin, 0o700)
      fixture = { directory:, tank:, key: File.join(tank, '.vpsfree-kb-ssh/ssh_host_ed25519_key'),
        events: File.join(directory, 'events'), script: File.join(directory, 'run'), error: File.join(directory, 'stderr') }
      File.write(fixture.fetch(:events), '', perm: 0o600)
      scripts = {
        'findmnt' => "printf 'mount\\n' >>\"$SSH_TEST_EVENTS\"\nprintf '%s\\n' \"$SSH_TEST_MOUNT\"\nexit \"$SSH_TEST_MOUNT_EXIT\"\n",
        'zfs' => "case \"$5\" in mounted) printf 'mounted\\n' >>\"$SSH_TEST_EVENTS\"; printf '%s\\n' \"$SSH_TEST_MOUNTED\";; mountpoint) printf 'mountpoint\\n' >>\"$SSH_TEST_EVENTS\"; printf '%s\\n' \"$SSH_TEST_MOUNTPOINT\";; *) exit 99;; esac\nexit \"$SSH_TEST_ZFS_EXIT\"\n",
        'mkdir' => "[ \"$SSH_TEST_MKDIR_EXIT\" = 0 ] || exit \"$SSH_TEST_MKDIR_EXIT\"\nexec #{Shellwords.escape(executable('mkdir'))} \"$@\"\n",
        'ssh-keygen' => "if [ \"$1\" = -t ]; then printf 'generate\\n' >>\"$SSH_TEST_EVENTS\"; [ \"$SSH_TEST_GENERATE_EXIT\" = 0 ] || exit \"$SSH_TEST_GENERATE_EXIT\"; else printf 'validate\\n' >>\"$SSH_TEST_EVENTS\"; fi\nexec #{Shellwords.escape(executable('ssh-keygen'))} \"$@\"\n",
        'daemon' => "printf 'daemon\\n' >>\"$SSH_TEST_EVENTS\"\n",
        'stat' => <<~SH
          value=$(#{Shellwords.escape(executable('stat'))} "$@") || exit $?
          owner=#{Process.uid}:#{Process.gid}
          case "$value" in "$owner"|"$owner":*) value="0:0${value#"$owner"}";; esac
          if [ "$3" = "$SSH_TEST_FOREIGN" ]; then value="1${value#0}"; fi
          printf '%s\n' "$value"
          exit "$SSH_TEST_STAT_EXIT"
        SH
      }
      scripts.each { |name, body| File.write(File.join(bin, name), "#!#{executable('bash')}\n#{body}", perm: 0o700) }
      run = projection.fetch('node').fetch('run').dup
      # Map only this generated body's fixed paths/storage probes into a private
      # fixture. Real stat modes/types and real Ed25519 generation remain active.
      run.gsub!('/tank', tank)
      run.gsub!('/etc/ssh', File.join(directory, 'etc/ssh'))
      projection.fetch('tools').each do |name, path|
        replacement = name == 'keygen' ? 'ssh-keygen' : File.join(bin, name)
        run.gsub!(path, replacement)
      end
      run.sub!(%r{^\s*exec /nix/store/[^\n]+/bin/sshd -D -f [^\n]+$}, "exec #{Shellwords.escape(File.join(bin, 'daemon'))}") || raise('missing actual OS daemon execution')
      FileUtils.mkdir_p(File.join(directory, 'etc'), mode: 0o700)
      prelude = <<~SH
        waitForService() {
          [ "$1" = pool-tank ] || return 99
          printf 'pool\n' >>"$SSH_TEST_EVENTS"
          if [ "$poolMode" = held ]; then
            printf 'pool\n' >&3
            read -r ready <&4 || return 1
            [ "$ready" = ready ] || return 1
          fi
        }
        poolMode="$1"
      SH
      File.write(fixture.fetch(:script), "#{prelude}\n#{run}", perm: 0o600)
      yield fixture
    end
  end

  def with_child(fixture)
    notification, notify = IO.pipe
    release_input, release = IO.pipe
    error = File.open(fixture.fetch(:error), File::WRONLY | File::CREAT | File::EXCL, 0o600)
    pid = Process.spawn(start_environment(fixture), executable('bash'), fixture.fetch(:script), 'held',
      3 => notify, 4 => release_input, out: File::NULL, err: error, close_others: true)
    notify.close
    release_input.close
    yield pid, notification, release
  ensure
    primary = $!
    release&.close unless release&.closed?
    if pid && !fixture[:reaped]
      begin
        wait_child(fixture, pid)
      rescue Timeout::Error
        # Sole wait owner still retains this exact, unreaped synthetic child.
        Thread.handle_interrupt(SignalException => :never) do
          Process.kill('KILL', pid)
          Process.waitpid2(pid)
          fixture[:reaped] = true
        end
        raise unless primary
      end
    end
    [notification, notify, release_input, release, error].compact.each { |io| io.close unless io.closed? }
  end

  def wait_child(fixture, pid)
    Timeout.timeout(5, Timeout::Error) do
      loop do
        result = Thread.handle_interrupt(SignalException => :never, Timeout::Error => :never) do
          pair = Process.waitpid2(pid, Process::WNOHANG)
          fixture[:reaped] = true if pair
          pair
        end
        return result.last if result
        IO.select([], [], [], 0.01)
      end
    end
  end
end
