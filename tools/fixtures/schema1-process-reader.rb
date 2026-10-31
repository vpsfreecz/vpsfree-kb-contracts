# frozen_string_literal: true

# Exact reader methods from KB7bdee285d62343c653b5a8c5cfdeab2d97ef7f4d
# cluster/lib/kb_runtime.rb; excerpts SHA256 3264a663b70c8ffd463a67b7cd2c1e850c06f5e814ce3b9f3b2372e94bdc8df1.
module KbRuntime
  class Schema1ProcessReader
    def process_record(record)
      path = state.path("processes-#{record.fetch('run_id')}.json")
      value = state.read(path)
      unless %w[instance_id run_id artifact_id artifact_sha256].all? { |key| value[key] == record[key] }
        raise Error, 'foreign process receipt'
      end
      value
    end

    def live?(record)
      ProcessIdentity.runner_matches?(process_record(record).fetch('runner'), record)
    rescue Errno::ENOENT
      false
    end

    # Readiness is a guarded snapshot, distinct from process ownership/liveness.
    def ready?(record = launch)
      current = phase
      return false unless current['phase'] == 'ready'

      validate_launch(record, current.fetch('run_id'))
      raise Error, 'readiness launch differs' unless launch == record
      begin
        marker = state.read(state.path("ready-#{record.fetch('run_id')}.json"))
      rescue Errno::ENOENT
        return false
      end
      unless marker['schema'] == 1 && %w[instance_id run_id artifact_id artifact_sha256].all? { |key| marker[key] == record[key] }
        raise Error, 'foreign readiness receipt'
      end
      live?(record)
    end

    def gone?(record)
      proof = process_record(record)
      proof.fetch('complete') == true && [proof.fetch('runner'), *proof.fetch('children')].all? { |process| ProcessIdentity.gone?(process) }
    end

    def control(record, command)
      handoff = pin_shutdown_paths(record)
      handoff[:runner] = process_record(record).fetch('runner')
      raise Error, 'runner identity does not match; no signal was sent' unless ProcessIdentity.runner_matches?(handoff[:runner], record)
      socket = UNIXSocket.new(handoff.fetch(:path))
      pid, uid, = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).unpack('iii')
      raise Error, 'foreign runner control peer' unless uid == Process.uid && pid == handoff[:runner].fetch('pid') && ProcessIdentity.runner_matches?(handoff[:runner], record)
      raise Error, 'runner launch changed before stop request' unless launch == record && process_record(record).fetch('runner') == handoff[:runner]
      check_shutdown_paths(handoff, required: true)
      set_phase('stopping', record.fetch('run_id'))
      socket.puts(JSON.generate('schema' => 1, 'instance_id' => record['instance_id'], 'run_id' => record['run_id'], 'command' => command))
      response = Timeout.timeout(5) { socket.gets(8193) }
      raise Error, 'invalid runner control response' unless response && response.bytesize <= 8192 && JSON.parse(response) == { 'schema' => 1, 'run_id' => record['run_id'], 'accepted' => true }
      socket.close
      socket = nil
      accepted = true
      handoff
    ensure
      socket&.close
      close_shutdown_paths(handoff) unless accepted
    end
    def check_shutdown_exit(handoff, record)
      proof = process_record(record)
      unless launch == handoff.fetch(:launch) && proof.fetch('runner') == handoff.fetch(:runner) && proof.fetch('complete') == true && [proof.fetch('runner'), *proof.fetch('children')].all? { |process| ProcessIdentity.gone?(process) }
        raise Error, 'shutdown handoff lacks unchanged complete exit proof'
      end
    end

    private :control, :check_shutdown_exit
  end
end
