#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'pathname'
require 'yaml'

class ManagedPageSourceError < StandardError; end

def path_within(root, relative)
  unless relative.is_a?(String)
    raise ManagedPageSourceError, "invalid relative path #{relative.inspect}"
  end

  root_path = Pathname.new(root).realpath
  path = root_path.join(relative).cleanpath
  unless path.to_s.start_with?("#{root_path}/")
    raise ManagedPageSourceError, "path escapes repository root: #{relative}"
  end

  path.to_s
end

def find_forbidden(path, label)
  File.readlines(path, encoding: Encoding::UTF_8).filter_map.with_index(1) do |line, number|
    next unless line.match?(/\bDEBIAN_FRONTEND\b/)

    "#{label}:#{number}: reader-visible DEBIAN_FRONTEND is not allowed"
  end
end

options = {
  contract: File.expand_path('../contract/pages.yml', __dir__),
  root: File.expand_path('..', __dir__)
}

OptionParser.new do |parser|
  parser.on('--contract FILE') { |value| options[:contract] = File.expand_path(value) }
  parser.on('--root DIR') { |value| options[:root] = File.expand_path(value) }
end.parse!
raise ManagedPageSourceError, 'unexpected arguments' unless ARGV.empty?

contract = YAML.safe_load_file(options.fetch(:contract))
raise ManagedPageSourceError, 'page contract schema must be 2' unless contract.fetch('schema') == 2

violations = []
contract.fetch('pages').each do |page_key, page_contract|
  page_contract.fetch('variants').each do |language, page|
    source = page.fetch('source')
    path = path_within(options.fetch(:root), source)
    violations.concat(find_forbidden(path, "#{page_key}:#{language}:#{source}"))
  end

  page_contract.fetch('samples', {}).each do |sample_id, sample|
    source = sample.fetch('path')
    path = path_within(options.fetch(:root), source)
    violations.concat(find_forbidden(path, "#{page_key}:sample:#{sample_id}:#{source}"))
  end
end

unless violations.empty?
  warn violations.join("\n")
  exit 1
end

puts 'Valid managed page sources: no reader-visible DEBIAN_FRONTEND'
