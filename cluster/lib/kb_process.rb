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
      record.is_a?(Hash) && record.keys.sort == ProcessReceipt::FULL && read(record.fetch('pid')) == record
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

    # Read only lifetime facts for descendants. Exec and credential transitions
    # can make /proc/PID/exe unreadable without ending this wait-only obligation.
    def lifetime_sample(pid)
      raise Error, 'invalid PID' unless ProcessReceipt.pid?(pid)
      read_stat = lambda do
        text = File.read("/proc/#{pid}/stat")
        leader, separator, fields = text.rpartition(') ')
        raise Error, 'malformed process stat' if separator.empty? || !leader.start_with?("#{pid} (")
        values = fields.split
        raise Error, 'malformed process stat' unless values.length > 19 && /\A[RSDZTtXxKWPIN]\z/.match?(values[0]) &&
          /\A[0-9]+\z/.match?(values[1]) && /\A[0-9]+\z/.match?(values[19])
        { 'pid' => pid, 'start_ticks' => Integer(values[19]), 'ppid' => Integer(values[1]), 'state' => values[0] }
      end
      boot = boot_id
      first = read_stat.call
      last = read_stat.call
      unless first.slice('pid', 'start_ticks', 'ppid') == last.slice('pid', 'start_ticks', 'ppid') && boot == boot_id
        raise Error, 'process lifetime changed during observation'
      end
      raise Error, 'invalid process start time' unless ProcessReceipt.ticks?(last['start_ticks'])
      return nil if %w[Z X].include?(last['state'])

      last.slice('pid', 'start_ticks', 'ppid').merge('boot_id' => boot)
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end

    def lifetime_key(record)
      record.values_at('boot_id', 'pid', 'start_ticks')
    end

    def lifetime_matches?(record)
      ProcessReceipt.lifetime?(record) && (sample = lifetime_sample(record['pid'])) && lifetime_key(sample) == lifetime_key(record)
    end

    def lifetime_gone?(record)
      return false unless ProcessReceipt.lifetime?(record) && record['boot_id'] == boot_id

      current = lifetime_sample(record['pid'])
      current.nil? || lifetime_key(current) != lifetime_key(record)
    end

    def descendants(pid, retained: [], observation: {})
      records = observation[:records] = []
      root = read(pid)
      raise Error, 'discovery root is unavailable' unless root
      visited = {}
      retained_by_key = retained.to_h { |record| [lifetime_key(record), record] }
      root_lifetime = root.slice('boot_id', 'pid', 'start_ticks')
      current = lambda do |record|
        if record.equal?(root_lifetime)
          raise Error, 'control identity changed during discovery' unless matches?(root)
          next true
        end
        next true if lifetime_matches?(record)
        if lifetime_gone?(record)
          observation[:incomplete] = true
          next false
        end
        raise Error, 'process lifetime changed during discovery'
      end
      descend = lambda do |parent|
        identity = lifetime_key(parent)
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
          sample = lifetime_sample(child)
          unless sample
            observation[:incomplete] = true
            next
          end
          key = lifetime_key(sample)
          record = retained_by_key[key]
          unless record
            raise Error, 'unproved descendant parent' unless sample['ppid'] == parent['pid']
            # Both sides of the parent/task-child relationship must still name
            # these same lifetimes before admitting a new descendant.
            unless current.call(parent) &&
                   children(parent['pid'], observation:).include?(child)
              observation[:incomplete] = true
              next
            end
            confirmed = lifetime_sample(child)
            unless confirmed && lifetime_key(confirmed) == key && confirmed['ppid'] == parent['pid'] && current.call(parent)
              observation[:incomplete] = true
              next
            end
            record = sample.slice('boot_id', 'pid', 'start_ticks').merge(
              'kind' => 'descendant-lifetime', 'parent' => parent.slice('boot_id', 'pid', 'start_ticks'))
            retained_by_key[key] = record
          end
          if visited[key]
            next
          end
          records << record
          descend.call(record)
        end
      end
      descend.call(root_lifetime)
      # Previously proved children remain obligations after reparenting. Never
      # traverse a replacement PID under the old lifetime's authority.
      retained.each do |record|
        next if visited[lifetime_key(record)] || lifetime_gone?(record)
        records << record
        descend.call(record)
      end
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

  # One versioned boundary for process proof. Control authenticates operations;
  # descendant lifetimes only prevent release until positively observed gone.
  module ProcessReceipt
    module_function

    IDS = %w[instance_id run_id artifact_id artifact_sha256].freeze
    FULL = %w[argv boot_id executable owner_uid pid start_ticks].freeze
    LIFE = %w[boot_id pid start_ticks].freeze

    def pid?(value)
      value.is_a?(Integer) && value > 1 && value <= 2**31 - 1
    end

    def ticks?(value)
      value.is_a?(Integer) && value >= 0 && value <= 2**53 - 1
    end

    def lifetime?(value)
      value.is_a?(Hash) && pid?(value['pid']) && ticks?(value['start_ticks']) && State::UUID.match?(value['boot_id'].to_s)
    end

    def full?(value, boot)
      lifetime?(value) && value.keys.sort == FULL && value['boot_id'] == boot && value['owner_uid'] == Process.uid &&
        value['executable'].is_a?(String) && value['executable'].start_with?('/') && !value['executable'].include?("\0") &&
        value['argv'].is_a?(Array) && value['argv'].all? { |arg| arg.is_a?(String) && !arg.include?("\0") }
    end

    def validate(value, launch)
      raise Error, 'foreign process receipt' unless value.is_a?(Hash) && IDS.all? { |key| value[key] == launch[key] } &&
        IDS.first(3).all? { |key| State::UUID.match?(value[key].to_s) } && /\A[0-9a-f]{64}\z/.match?(value['artifact_sha256'].to_s)
      keys = case value['schema']
             when 1 then IDS + %w[schema runner children complete]
             when 2 then IDS + %w[schema control descendants complete tracking_error]
             else raise Error, 'unsupported process receipt schema'
             end
      raise Error, 'malformed process receipt' unless value.keys.sort == keys.sort && [true, false].include?(value['complete'])
      owner = control(value)
      raise Error, 'invalid process control identity' unless full?(owner, launch.fetch('boot_id'))
      children = descendants(value)
      raise Error, 'invalid process descendants' unless children.is_a?(Array)
      if value['schema'] == 1
        raise Error, 'invalid legacy child identity' unless children.all? { |child| full?(child, owner['boot_id']) && child['pid'] != owner['pid'] }
      else
        error = value['tracking_error']
        unless error.nil? || (error.is_a?(Hash) && error.keys.sort == %w[class message] &&
            error['class'].is_a?(String) && error['class'].bytesize.between?(1, 256) &&
            error['message'].is_a?(String) && error['message'].bytesize <= 2048 &&
            error.values.none? { |text| text.include?("\0") })
          raise Error, 'invalid tracking failure'
        end
        raise Error, 'failed tracking cannot prove completion' if error && value['complete']
        children.each do |child|
          unless lifetime?(child) && child.keys.sort == %w[boot_id kind parent pid start_ticks] &&
              child['kind'] == 'descendant-lifetime' && child['boot_id'] == owner['boot_id'] &&
              lifetime?(child['parent']) && child['parent'].keys.sort == LIFE && child['parent']['boot_id'] == owner['boot_id'] &&
              child['pid'] != owner['pid']
            raise Error, 'invalid descendant lifetime'
          end
        end
      end
      indexed = children.to_h { |child| [ProcessIdentity.lifetime_key(child), child] }
      raise Error, 'duplicate process lifetime' unless indexed.size == children.size
      if value['schema'] == 2
        anchor = ProcessIdentity.lifetime_key(owner)
        children.each do |child|
          seen = {}
          key = ProcessIdentity.lifetime_key(child)
          until key == anchor
            raise Error, 'unanchored or cyclic descendant ancestry' if seen[key] || !indexed.key?(key)
            seen[key] = true
            key = ProcessIdentity.lifetime_key(indexed.fetch(key).fetch('parent'))
          end
        end
      end
      value
    end

    def control(value)
      value.fetch(value.fetch('schema') == 1 ? 'runner' : 'control')
    end

    def descendants(value)
      value.fetch(value.fetch('schema') == 1 ? 'children' : 'descendants')
    end

    def healthy?(value)
      value['schema'] == 1 || value['tracking_error'].nil?
    end

    def gone?(value)
      value.fetch('complete') && healthy?(value) && ProcessIdentity.gone?(control(value)) &&
        descendants(value).all? { |child| value['schema'] == 1 ? ProcessIdentity.gone?(child) : ProcessIdentity.lifetime_gone?(child) }
    end
  end
end
