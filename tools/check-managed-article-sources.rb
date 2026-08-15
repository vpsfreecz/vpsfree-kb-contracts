#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'pathname'
require 'yaml'

class ManagedArticleSourceError < StandardError; end

def path_within(root, relative)
  unless relative.is_a?(String)
    raise ManagedArticleSourceError, "invalid relative path #{relative.inspect}"
  end

  root_path = Pathname.new(root).realpath
  path = root_path.join(relative).cleanpath
  unless path.to_s.start_with?("#{root_path}/")
    raise ManagedArticleSourceError, "path escapes repository root: #{relative}"
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
  contract: File.expand_path('../contract/articles.yml', __dir__),
  root: File.expand_path('..', __dir__)
}

OptionParser.new do |parser|
  parser.on('--contract FILE') { |value| options[:contract] = File.expand_path(value) }
  parser.on('--root DIR') { |value| options[:root] = File.expand_path(value) }
end.parse!
raise ManagedArticleSourceError, 'unexpected arguments' unless ARGV.empty?

contract = YAML.safe_load_file(options.fetch(:contract))
raise ManagedArticleSourceError, 'article contract schema must be 1' unless contract.fetch('schema') == 1

violations = []
contract.fetch('articles').each do |article_id, article|
  article.fetch('pages').each do |language, page|
    source = page.fetch('source')
    path = path_within(options.fetch(:root), source)
    violations.concat(find_forbidden(path, "#{article_id}:#{language}:#{source}"))
  end

  article.fetch('samples', {}).each do |sample_id, sample|
    source = sample.fetch('path')
    path = path_within(options.fetch(:root), source)
    violations.concat(find_forbidden(path, "#{article_id}:sample:#{sample_id}:#{source}"))
  end
end

unless violations.empty?
  warn violations.join("\n")
  exit 1
end

puts 'Valid managed article sources: no reader-visible DEBIAN_FRONTEND'
