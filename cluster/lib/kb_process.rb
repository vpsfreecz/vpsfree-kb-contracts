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

    def children(pid, observation: {})
      raise Error, 'invalid PID' unless pid.is_a?(Integer) && pid > 1
      directory = "/proc/#{pid}/task"
      tasks = Dir.children(directory)
      valid_tasks = ->(values) do
        raise Error, 'invalid task ID' unless values.all? { |value| /\A[1-9][0-9]*\z/.match?(value) }
        values.sort
      end
      tasks = valid_tasks.call(tasks)
      found = tasks.flat_map do |task|
        path = "#{directory}/#{task}"
        begin
          values = File.read("#{path}/children").split
        rescue Errno::ENOENT, Errno::ESRCH => failure
          begin
            File.stat(path)
          rescue Errno::ENOENT, Errno::ESRCH
            observation[:incomplete] = true
            next []
          end
          # Missing child data for a still-live task is not an empty list.
          raise failure
        end
        raise Error, 'invalid child PID' unless values.all? { |value| /\A[1-9][0-9]*\z/.match?(value) && Integer(value) > 1 }
        values.map { |value| Integer(value) }
      end
      observation[:incomplete] = true unless valid_tasks.call(Dir.children(directory)) == tasks
      found.uniq
    end

    def descendants(pid, observation: {})
      records = observation[:records] = []
      root = read(pid)
      raise Error, 'discovery root is unavailable' unless root
      visited = {}
      observed = { pid => root }
      current = lambda do |record|
        next true if matches?(record)
        if gone?(record)
          observation[:incomplete] = true
          next false
        end
        raise Error, 'process identity changed during discovery'
      end
      descend = lambda do |parent|
        identity = [parent['boot_id'], parent['pid'], parent['start_ticks']]
        next if visited[identity]
        visited[identity] = true
        next unless current.call(parent)
        begin
          pids = children(parent.fetch('pid'), observation:)
        rescue Errno::ENOENT, Errno::ESRCH
          raise if current.call(parent)
          next
        end
        next unless current.call(parent)
        pids.each do |child|
          record = read(child)
          unless record
            observation[:incomplete] = true
            next
          end
          previous = observed[child]
          if previous && previous != record
            raise Error, 'process identity changed during discovery' if current.call(previous)
            next
          end
          observed[child] = record
          child_identity = [record['boot_id'], child, record['start_ticks']]
          next if visited[child_identity]
          records << record
          descend.call(record)
        end
      end
      descend.call(root)
      records
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
