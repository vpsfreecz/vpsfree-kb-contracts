#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'rbconfig'
require_relative 'lib/kb_runtime'

module KbRuntime
  class CLI
    def self.run(argv, source_root: File.expand_path('..', __dir__))
      options = { root: File.join(source_root, '.devcluster', 'v2'), topology: 'single', network: 'bridge', timeout: 900 }
      parser = OptionParser.new do |value|
        value.banner = 'Usage: devcluster [--state-root DIR] COMMAND SLUG [options]'
        value.on('--state-root DIR') { |v| options[:root] = v }
        value.on('--software-metadata FILE') { |v| options[:metadata] = v }
        value.on('--topology NAME') { |v| options[:topology] = v; options[:topology_supplied] = true }
        value.on('--network MODE') { |v| options[:network] = v; options[:network_supplied] = true }
        value.on('--config FILE') { |v| options[:config] = v }
        value.on('--timeout SECONDS', Integer) { |v| options[:timeout] = v }
        value.on('--instance-id ID') { |v| options[:instance] = v }
        value.on('--run-id ID') { |v| options[:run] = v }
        value.on('--artifact-id ID') { |v| options[:artifact] = v }
        value.on('--artifact-sha256 SHA') { |v| options[:artifact_digest] = v }
        value.on('--descriptor-sha256 SHA') { |v| options[:digest] = v }
        value.on('--json') {}
        value.on('--help') { puts value; return 0 }
      end
      parser.permute!(argv)
      command, slug, *rest = argv
      raise Error, 'command and slug are required' unless command && slug
      raise Error, 'network mode must be bridge or local' unless %w[bridge local].include?(options[:network])
      state = State.new(options[:root], slug)
      software = if %w[start resume update].include?(command)
                   options[:metadata] ? Software.new(JSON.parse(File.read(options[:metadata]))) : Software.checkout(source_root)
                 end
      controller = [RbConfig.ruby, File.expand_path(__FILE__)]
      controller += ['--software-metadata', options[:metadata]] if options[:metadata]
      engine = Engine.new(state:, software:, controller:)
      case command
      when 'start', 'update'
        raise Error, 'explicit dedicated cluster config is required' unless options[:config]
        config = JSON.parse(File.read(options[:config]))
        defaults = JSON.parse(File.read(File.join(source_root, 'cluster', 'default-config.json')))
        merged = resolve_config(defaults, config, options[:network], options[:topology])
        engine.public_send(command, config: merged, topology: options[:topology], network: options[:network], timeout: options[:timeout])
        puts JSON.generate(engine.status)
      when 'resume'
        raise Error, 'resume accepts no replacement config, topology or network' if options[:config] || options[:topology_supplied] || options[:network_supplied]
        engine.resume(timeout: options[:timeout])
        puts JSON.generate(engine.status)
      when 'stop'
        engine.stop(timeout: options[:timeout])
      when 'reset'
        engine.reset
      when 'status'
        puts JSON.generate(engine.status)
      when 'connection'
        puts engine.connection
      when 'capture-lease'
        engine.capture_lease(instance_id: options.fetch(:instance), run_id: options.fetch(:run),
          artifact_id: options.fetch(:artifact), artifact_sha256: options.fetch(:artifact_digest), descriptor_sha256: options.fetch(:digest))
      when 'cleanup-paths'
        state.transaction(wait: false) do
          record = engine.launch
          raise Error, 'owned shutdown must finish before cleanup' unless engine.phase['phase'] == 'stopped' && engine.gone?(record)
          puts JSON.generate('schema' => 1, 'paths' => [state.directory, record.fetch('socket_dir')])
        end
      when 'transition-adopt'
        state.transaction(wait: false) do
          state.identity
          record = engine.launch
          raise Error, 'unsupported retained runner/source receipt' unless record.fetch('source').fetch('schema') == 1 && record.fetch('guest_identity').fetch('schema') == 1
          engine.resources.socket_dir(record['instance_id'], record['run_id']) == record['socket_dir'] || raise(Error, 'recorded socket differs')
          raise Error, 'ambiguous retained process identity' unless engine.live?(record) || engine.gone?(record)
        end
      when 'ssh'
        machine, *remote = rest
        remote.shift if remote.first == '--'
        state.lock('gate') { puts engine.ssh(engine.launch, machine, *remote) }
      when 'refresh'
        state.transaction { engine.refresh }
      when 'config'
        state.identity
        puts state.file(engine.launch.fetch('input_path'))
      else
        raise Error, "unsupported command: #{command}"
      end
      0
    rescue Busy => error
      warn error.message
      75
    rescue Error, KeyError, OptionParser::ParseError, Errno::ENOENT, JSON::ParserError => error
      warn "error: #{error.message}"
      1
    end

    def self.resolve_config(defaults, requested, network, topology)
      raise Error, 'cluster configuration must be an object' unless requested.is_a?(Hash)
      effective = deep_merge(defaults, requested)
      machines = ['services', *effective.fetch('topologies').fetch(topology)]
      machines += effective.fetch('dns', {}).fetch('servers', {}).keys if effective.dig('dns', 'enable')
      if network == 'local'
        effective['local'] = requested.fetch('local')
      else
        dedicated = requested.fetch('network')
        raise Error, 'explicit dedicated bridge configuration is required' unless dedicated['dedicated'] == true && dedicated.key?('bridge') && dedicated.key?('gateway')
        machines.each do |name|
          settings = name == 'services' ? requested['services'] : requested.fetch('nodes', {})[name] || requested.fetch('dns', {}).fetch('servers', {})[name]
          raise Error, "explicit dedicated address is required for #{name}" unless settings.is_a?(Hash) && settings.key?('ip')
        end
      end
      effective
    end

    def self.deep_merge(left, right)
      left.merge(right) { |_key, old, replacement| old.is_a?(Hash) && replacement.is_a?(Hash) ? deep_merge(old, replacement) : replacement }
    end
  end
end

exit KbRuntime::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
