# frozen_string_literal: true

require 'json'
require 'osvm'
require 'shellwords'
require 'test-runner/hook'

class KbVpsadminctl
  def initialize(machine)
    @machine = machine
  end

  def succeeds(args:, parameters: {}, timeout: nil)
    command = ['vpsadminctl', '--raw', *Array(args).map(&:to_s)]
    command.concat(['--', *format(parameters)]) unless parameters.empty?
    _, output = if timeout
                  @machine.succeeds(Shellwords.join(command), timeout:)
                else
                  @machine.succeeds(Shellwords.join(command))
                end
    JSON.parse(json_prefix(output))
  end

  private

  def format(parameters)
    parameters.flat_map do |key, value|
      option = "--#{key.to_s.tr('_', '-')}"

      case value
      when true
        [option]
      when false
        ["--no-#{key.to_s.tr('_', '-')}"]
      when nil
        []
      when Array
        value.flat_map { |item| [option, item.to_s] }
      else
        [option, value.to_s]
      end
    end
  end

  def json_prefix(output)
    start = output.index(/[\[{]/)
    raise JSON::ParserError, 'vpsadminctl returned no JSON' unless start

    stack = []
    in_string = false
    escaped = false

    output.chars.each_with_index do |character, index|
      next if index < start

      if in_string
        if escaped
          escaped = false
        elsif character == '\\'
          escaped = true
        elsif character == '"'
          in_string = false
        end
        next
      end

      case character
      when '"'
        in_string = true
      when '{'
        stack << '}'
      when '['
        stack << ']'
      when '}', ']'
        raise JSON::ParserError, 'unbalanced vpsadminctl JSON' unless stack.pop == character
        return output[start..index] if stack.empty?
      end
    end

    raise JSON::ParserError, 'incomplete vpsadminctl JSON'
  end
end

class KbVpsadminServicesMachine < OsVm::NixosMachine
  attr_reader :vpsadminctl

  def initialize(*args, **kwargs)
    super
    @vpsadminctl = KbVpsadminctl.new(self)
  end

  def wait_for_vpsadmin_api(timeout: @default_timeout || 300)
    deadline = Time.now + timeout

    loop do
      remaining = deadline - Time.now
      raise OsVm::TimeoutError, 'vpsAdmin API did not become ready' if remaining <= 0

      _, output = wait_until_succeeds(
        'curl --silent --fail-with-body http://api.vpsadmin.test/',
        timeout: remaining.ceil
      )
      return true if output.include?('API description')

      sleep 1
    end
  rescue OsVm::TimeoutError => readiness_error
    begin
      execute(<<~'SH', timeout: 30)
        set +e
        systemctl status --no-pager --full \
          vpsadmin-database-setup.service \
          vpsadmin-devcluster-seed.service \
          vpsadmin-notification-templates.service \
          vpsadmin-api.service
        journalctl --no-pager --output=short-precise --lines=400 \
          --unit=vpsadmin-database-setup.service \
          --unit=vpsadmin-devcluster-seed.service \
          --unit=vpsadmin-notification-templates.service \
          --unit=vpsadmin-api.service
        ps axo pid,ppid,state,etime,%cpu,%mem,command --forest
        exit 0
      SH
    rescue StandardError => diagnostic_error
      warn(
        'Unable to collect vpsAdmin API diagnostics: ' \
        "#{diagnostic_error.class}: #{diagnostic_error.message}"
      )
    end

    raise readiness_error
  end

  def api_ruby_json(code:, timeout: nil)
    script = <<~CMD
      set -euo pipefail
      api_dir="$(systemctl show -p WorkingDirectory --value vpsadmin-api)"
      api_root="$(dirname "$api_dir")"
      script="$(mktemp /tmp/vpsadmin-kb-XXXX.rb)"
      trap 'rm -f "$script"' EXIT

      cat >"$script" <<'RUBY'
      ENV['RACK_ENV'] ||= 'production'
      require 'json'
      Dir.chdir(ENV.fetch('API_DIR'))
      $LOAD_PATH.unshift(File.join(ENV.fetch('API_DIR'), 'lib'))
      require 'vpsadmin'
      #{code}
      RUBY

      API_DIR="$api_dir" "$api_root/ruby-env-wrapped/bin/ruby" "$script"
    CMD

    _, output = timeout ? succeeds(script, timeout:) : succeeds(script)
    JSON.parse(output.to_s.lines.last)
  end
end

TestRunner::Hook.subscribe(:machine_class_for) do |machine_config|
  next unless machine_config.tags.include?('vpsadmin-services')

  KbVpsadminServicesMachine
end
