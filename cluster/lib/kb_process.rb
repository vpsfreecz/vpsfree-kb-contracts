# frozen_string_literal: true

require_relative 'kb_state'

module KbRuntime
  # A PID is only an index. Every observation is bound to a boot and start time.
  module ProcessIdentity
    module_function

    def boot_id
      File.read('/proc/sys/kernel/random/boot_id').strip
    end

    def read(pid)
      raise Error, 'invalid PID' unless pid.is_a?(Integer) && pid > 1
      base = "/proc/#{pid}"
      stat = File.read("#{base}/stat").split(') ', 2).last.split
      return nil if stat[0] == 'Z'

      { 'pid' => pid, 'start_ticks' => Integer(stat[19]), 'boot_id' => boot_id,
        'owner_uid' => File.stat(base).uid, 'executable' => File.readlink("#{base}/exe"),
        'argv' => File.binread("#{base}/cmdline").split("\0") }
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end

    def matches?(record)
      record.is_a?(Hash) && read(record.fetch('pid')) == record
    rescue KeyError, Error
      false
    end

    def gone?(record)
      return false unless record.is_a?(Hash) && record['boot_id'] == boot_id && record['owner_uid'] == Process.uid

      current = read(record.fetch('pid'))
      current.nil? || current['start_ticks'] != record['start_ticks']
    rescue KeyError, Error
      false
    end

    def children(pid)
      File.read("/proc/#{pid}/task/#{pid}/children").split.map { |value| Integer(value) }
    rescue Errno::ENOENT
      []
    end

    def descendants(pid)
      children(pid).flat_map do |child|
        record = read(child)
        record ? [record, *descendants(child)] : []
      end
    end

    def runner_matches?(record, launch)
      return false unless matches?(record) && record['owner_uid'] == Process.uid && record['boot_id'] == launch['boot_id']
      expected = launch.fetch('runner_identity')
      return false unless record['executable'] == File.realpath(expected.fetch('executable')) && record['argv'].include?(expected.fetch('entrypoint'))

      pairs = { '--config' => launch['config_path'], '--state-dir' => launch['state_dir'],
                '--sock-dir' => launch['socket_dir'], '--run-id' => launch['run_id'],
                '--instance-id' => launch['instance_id'], '--artifact-id' => launch['artifact_id'],
                '--artifact-sha256' => launch['artifact_sha256'] }
      pairs.all? { |option, value| record['argv'].each_cons(2).include?([option, value]) }
    end
  end
end
