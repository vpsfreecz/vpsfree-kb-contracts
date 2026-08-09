#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'optparse'
require 'yaml'

class RuntimeContractError < StandardError; end

def normalize(value)
  value.gsub(/\s+/, ' ').strip
end

def sections(source)
  matches = source.enum_for(:scan, /^===== ([^\n]+) =====\s*$/).map do
    [Regexp.last_match(1), Regexp.last_match.begin(0)]
  end

  matches.each_with_index.to_h do |(heading, offset), index|
    limit = matches[index + 1]&.last || source.length
    [heading, source[offset...limit]]
  end
end

options = {
  contract: File.expand_path('../contract/runtime.yml', __dir__),
  root: File.expand_path('..', __dir__)
}

OptionParser.new do |parser|
  parser.on('--contract FILE') { |value| options[:contract] = File.expand_path(value) }
  parser.on('--root DIR') { |value| options[:root] = File.expand_path(value) }
end.parse!

contract = YAML.safe_load_file(options.fetch(:contract))
root = options.fetch(:root)
raise RuntimeContractError, 'runtime contract schema must be 1' unless contract.fetch('schema') == 1

lock = JSON.parse(File.read(File.join(root, 'flake.lock')))
captures = JSON.parse(File.read(File.join(root, 'captures.json')))
revisions = contract.fetch('revisions')

%w[vpsadmin vpsadminos].each do |input|
  actual = lock.dig('nodes', input, 'locked', 'rev')
  expected = revisions.fetch(input)
  raise RuntimeContractError, "#{input} revision differs: expected #{expected}, got #{actual}" unless actual == expected
end

unless captures.fetch('vpsadmin_commit') == revisions.fetch('vpsadmin')
  raise RuntimeContractError, 'runtime and capture vpsAdmin revisions differ'
end

workflow = File.read(File.join(root, '.github/workflows/kvm-runtime.yml'))
workflow_revisions = workflow.scan(%r{vpsfreecz/vpsadminos/[^@\s]+@([0-9a-f]{40})}).flatten.uniq
unless workflow_revisions == [revisions.fetch('vpsadminos')]
  raise RuntimeContractError, 'KVM workflow does not use the pinned vpsAdminOS revision'
end

test_source = File.read(File.join(root, 'tests/suite/kb/kvm.nix'))
tests = contract.fetch('tests')
test_ids = tests.flat_map do |test_name, definition|
  definition.fetch('scripts').map do |script|
    id = "#{test_name}##{script}"
    pattern = /^\s{6}#{Regexp.escape(script)} = mkScript\b/
    raise RuntimeContractError, "missing test script #{id}" unless test_source.match?(pattern)
    id
  end
end
raise RuntimeContractError, 'duplicate runtime test IDs' unless test_ids.uniq.length == test_ids.length
unless test_source.include?('tags = [ "kb-runtime" ];')
  raise RuntimeContractError, 'every runtime test script must carry the kb-runtime tag'
end

samples = contract.fetch('samples')
sample_ids = samples.keys
samples.each do |id, sample|
  path = File.join(root, sample.fetch('path'))
  raise RuntimeContractError, "#{id}: sample file is missing" unless File.file?(path)

  actual = Digest::SHA256.file(path).hexdigest
  expected = sample.fetch('sha256')
  raise RuntimeContractError, "#{id}: sample SHA-256 differs" unless actual == expected

  unknown_tests = sample.fetch('tests') - test_ids
  unless unknown_tests.empty?
    raise RuntimeContractError, "#{id}: unknown tests #{unknown_tests.join(', ')}"
  end
end

page_ids = []
page_sections = {}
used_tests = []
used_samples = []
contract.fetch('pages').each do |page|
  id = page.fetch('id')
  page_ids << id
  path = File.join(root, page.fetch('source'))
  raise RuntimeContractError, "#{id}: page source is missing" unless File.file?(path)

  source = File.read(path)
  unless source.start_with?("<page>#{page.fetch('counterpart')}</page>\n")
    raise RuntimeContractError, "#{id}: counterpart mapping differs"
  end

  source_sections = sections(source)
  contracted_headings = page.fetch('sections').map { |section| section.fetch('heading') }
  unless source_sections.keys == contracted_headings
    raise RuntimeContractError, "#{id}: section heading set or order differs"
  end

  section_contracts = page.fetch('sections').to_h do |section|
    key = section.fetch('key')
    heading = section.fetch('heading')
    body = source_sections.fetch(heading)
    fingerprint = Digest::SHA256.hexdigest(normalize(body))
    unless fingerprint == section.fetch('fingerprint')
      raise RuntimeContractError, "#{id}: section fingerprint differs for #{heading}"
    end

    section_tests = section.fetch('tests')
    section_samples = section.fetch('samples')
    unknown_tests = section_tests - test_ids
    unknown_samples = section_samples - sample_ids
    unless unknown_tests.empty?
      raise RuntimeContractError, "#{id}: #{heading}: unknown tests #{unknown_tests.join(', ')}"
    end
    unless unknown_samples.empty?
      raise RuntimeContractError, "#{id}: #{heading}: unknown samples #{unknown_samples.join(', ')}"
    end

    section_samples.each do |sample_id|
      sample = File.read(File.join(root, samples.fetch(sample_id).fetch('path'))).strip
      unless body.include?("<code bash>\n#{sample}\n</code>")
        raise RuntimeContractError, "#{id}: #{heading}: exact sample #{sample_id} is missing"
      end
    end

    claims = section.fetch('claims')
    raise RuntimeContractError, "#{id}: #{heading}: claims must not be empty" if claims.empty?
    used_tests.concat(section_tests)
    used_samples.concat(section_samples)

    [key, {
      'claims' => claims,
      'tests' => section_tests,
      'samples' => section_samples
    }]
  end
  unless section_contracts.length == page.fetch('sections').length
    raise RuntimeContractError, "#{id}: duplicate section keys"
  end
  page_sections[id] = section_contracts
end

raise RuntimeContractError, 'duplicate runtime page IDs' unless page_ids.uniq.length == page_ids.length
unless used_tests.uniq.sort == test_ids.sort
  raise RuntimeContractError, 'every runtime test must be bound to at least one page section'
end
unless used_samples.uniq.sort == sample_ids.sort
  raise RuntimeContractError, 'every executable sample must be bound to at least one page section'
end

required_pages = %w[navody:vps:kvm manuals:vps:kvm]
unless page_ids.sort == required_pages.sort
  raise RuntimeContractError, 'runtime pages must be the Czech and English KVM pages'
end

contract.fetch('pages').each do |page|
  id = page.fetch('id')
  counterpart = page.fetch('counterpart')
  counterpart_page = contract.fetch('pages').find { |candidate| candidate.fetch('id') == counterpart }
  unless counterpart_page&.fetch('counterpart') == id
    raise RuntimeContractError, "#{id}: counterpart mapping is not reciprocal"
  end
  unless page_sections.fetch(id) == page_sections.fetch(counterpart)
    raise RuntimeContractError, "#{id}: bilingual section contracts differ from #{counterpart}"
  end
end

%w[vps-details/feature-settings vps-details/datasets].each do |capture_id|
  asset = captures.fetch('assets').find { |item| item.fetch('id') == capture_id }
  raise RuntimeContractError, "missing capture #{capture_id}" unless asset

  expected = {
    'cs' => ['navody:vps:kvm'],
    'en' => ['manuals:vps:kvm']
  }
  actual = asset.fetch('variants').to_h do |language, variant|
    [language, variant.dig('wiki', 'source_pages')]
  end
  raise RuntimeContractError, "#{capture_id}: KVM page bindings differ" unless actual == expected
end

puts "Valid runtime contract: #{page_ids.length} pages, #{test_ids.length} tests, " \
     "#{sample_ids.length} executable samples"
