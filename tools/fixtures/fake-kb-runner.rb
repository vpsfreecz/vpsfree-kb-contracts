#!/usr/bin/env ruby
# frozen_string_literal: true
require 'optparse'
require 'socket'
require_relative '../../cluster/lib/kb_process'
require_relative '../../cluster/lib/kb_disks'

ARGV.shift # start
options = {}
OptionParser.new do |parser|
  %w[config state-dir sock-dir instance-id run-id artifact-id artifact-sha256 launch-file state-root slug timeout].each do |name|
    parser.on("--#{name} VALUE") { |value| options[name] = value }
  end
end.parse!
state = KbRuntime::State.new(options.fetch('state-root'), options.fetch('slug'))
launch = state.read(options.fetch('launch-file'))
runner = KbRuntime::ProcessIdentity.read(Process.pid)
raise 'fake runner tuple differs' unless KbRuntime::ProcessIdentity.runner_matches?(runner, launch)
artifact = state.read(state.path("artifact-#{launch.fetch('artifact_id')}.json"))
preparation = KbRuntime::DiskPreparation.new(state, artifact)
preparation.prepare('services', { 'root' => { 'path' => File.join(launch.fetch('state_dir'), 'services-root.img') } }) do
  File.open(File.join(launch.fetch('state_dir'), 'services-root.img'), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write('root sentinel')
  end
end
reader, writer = IO.pipe
child = Process.spawn(RbConfig.ruby, '-e', 'STDIN.read', in: reader, close_others: true)
reader.close
children = [KbRuntime::ProcessIdentity.read(child)]
record = { 'schema' => 1, 'instance_id' => launch['instance_id'], 'run_id' => launch['run_id'],
           'artifact_id' => launch['artifact_id'], 'artifact_sha256' => launch['artifact_sha256'],
           'runner' => runner, 'children' => children, 'complete' => false }
process_path = state.path("processes-#{launch['run_id']}.json")
control = File.join(options.fetch('sock-dir'), 'control.sock')
state.lock('runner', create: true) do
  server = UNIXServer.new(control)
  File.chmod(0o600, control)
  state.write(process_path, record)
  state.write(state.path("ready-#{launch['run_id']}.json"), record.slice('schema', 'instance_id', 'run_id', 'artifact_id', 'artifact_sha256'), immutable: true)
  peer = server.accept
  request = JSON.parse(peer.gets)
  raise 'fake control identity differs' unless request == record.slice('schema', 'instance_id', 'run_id').merge('command' => 'stop')
  peer.puts(JSON.generate('schema' => 1, 'run_id' => launch['run_id'], 'accepted' => true))
  peer.close
  writer.close
  Process.wait(child)
  state.write(process_path, record.merge('complete' => true))
  server.close
  File.unlink(control)
end
