#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'yaml'

class ArticleContractError < StandardError; end

DISPLAY_LANGUAGES = %w[cs en].freeze
TOOL_DIRECTIVE = /\A[ \t]*#(?:[ \t]*(?:shellcheck|shfmt|nix-shell)\b|[ \t]*syntax=)/

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

def managed_marker(source_url, test_url)
  <<~MARKER.chomp
    <kb-managed
      source="#{source_url}"
      test="#{test_url}"
    />
  MARKER
end

def comment_parts(line, code_language)
  return nil if line.match?(/\A[ \t]*#!/) || line.match?(TOOL_DIRECTIVE)

  pattern = if code_language == 'scheme'
              /\A(?<indent>[ \t]*)(?<marker>;+)(?<spacing>[ \t]*)(?<text>.*)\z/
            else
              /\A(?<indent>[ \t]*)(?<marker>#+)(?<spacing>[ \t]*)(?<text>.*)\z/
            end
  match = line.match(pattern)
  return nil unless match

  {
    shape: [match[:indent], match[:marker], match[:spacing]],
    text: match[:text]
  }
end

def display_sources(article_id, sample_id, sample, runtime_source, code_language)
  runtime_lines = runtime_source.split("\n", -1)
  comments = runtime_lines.each_with_index.filter_map do |line, index|
    parts = comment_parts(line, code_language)
    [index + 1, parts] if parts
  end.to_h
  variants = sample['display_variants']

  if comments.empty?
    if variants
      raise ArticleContractError,
            "#{article_id}: #{sample_id}: display variants require human-readable comments"
    end

    return DISPLAY_LANGUAGES.to_h { |language| [language, runtime_source] }
  end

  unless variants.is_a?(Hash) && variants.keys.sort == DISPLAY_LANGUAGES
    raise ArticleContractError,
          "#{article_id}: #{sample_id}: display variants must contain exactly cs and en"
  end

  sources = variants.to_h do |language, variant|
    unless variant.is_a?(Hash) && variant.keys == ['comments']
      raise ArticleContractError,
            "#{article_id}: #{sample_id}: #{language}: display variant must contain only comments"
    end

    replacements = variant.fetch('comments')
    unless replacements.is_a?(Hash)
      raise ArticleContractError,
            "#{article_id}: #{sample_id}: #{language}: display comments must be a mapping"
    end

    invalid_lines = replacements.keys.reject { |line| line.is_a?(Integer) && comments.key?(line) }
    unless invalid_lines.empty?
      raise ArticleContractError,
            "#{article_id}: #{sample_id}: #{language}: line #{invalid_lines.first} " \
            'is not a human-readable comment'
    end

    missing_lines = comments.keys - replacements.keys
    unless missing_lines.empty?
      raise ArticleContractError,
            "#{article_id}: #{sample_id}: #{language}: missing display comment for line " \
            "#{missing_lines.first}"
    end

    lines = runtime_lines.dup
    replacements.each do |line_number, replacement|
      unless replacement.is_a?(String)
        raise ArticleContractError,
              "#{article_id}: #{sample_id}: #{language}: display comment must be a string"
      end

      replacement_parts = comment_parts(replacement, code_language)
      unless replacement_parts && replacement_parts.fetch(:shape) == comments.fetch(line_number).fetch(:shape)
        raise ArticleContractError,
              "#{article_id}: #{sample_id}: #{language}: comment line structure differs at line " \
              "#{line_number}"
      end
      lines[line_number - 1] = replacement
    end

    [language, lines.join("\n")]
  end

  comments.each_key do |line_number|
    cs = comment_parts(sources.fetch('cs').split("\n", -1).fetch(line_number - 1), code_language)
    en = comment_parts(sources.fetch('en').split("\n", -1).fetch(line_number - 1), code_language)
    next if cs.fetch(:text).empty? && en.fetch(:text).empty?
    next unless cs.fetch(:text) == en.fetch(:text)

    raise ArticleContractError,
          "#{article_id}: #{sample_id}: human-readable comment is not localized at line " \
          "#{line_number}"
  end

  cs_lines = sources.fetch('cs').split("\n", -1)
  en_lines = sources.fetch('en').split("\n", -1)
  unless cs_lines.length == en_lines.length
    raise ArticleContractError, "#{article_id}: #{sample_id}: display line structure differs"
  end
  cs_lines.zip(en_lines).each_with_index do |(cs, en), index|
    next if comment_parts(cs, code_language) && comment_parts(en, code_language)
    next if cs == en

    kind = cs.match?(/\A[ \t]*#!/) || cs.match?(TOOL_DIRECTIVE) ? 'shebang/tool directive' :
      'non-comment executable line'
    raise ArticleContractError,
          "#{article_id}: #{sample_id}: #{kind} differs at line #{index + 1}"
  end

  sources
end

def path_within(root, relative)
  raise ArticleContractError, "invalid relative path #{relative.inspect}" unless relative.is_a?(String)

  root_path = Pathname.new(root).realpath
  path = root_path.join(relative).cleanpath
  unless path.to_s.start_with?("#{root_path}/")
    raise ArticleContractError, "path escapes repository root: #{relative}"
  end

  path.to_s
end

def load_tests_meta(root, file)
  return JSON.parse(File.read(file)) if file

  output, error, status = Open3.capture3(
    'nix', 'eval', '--json', '.#testsMeta.x86_64-linux',
    chdir: root
  )
  unless status.success?
    raise ArticleContractError, "unable to evaluate test metadata: #{error.strip}"
  end

  JSON.parse(output)
end

options = {
  contract: File.expand_path('../contract/articles.yml', __dir__),
  root: File.expand_path('..', __dir__),
  tests_meta: nil
}

OptionParser.new do |parser|
  parser.on('--contract FILE') { |value| options[:contract] = File.expand_path(value) }
  parser.on('--root DIR') { |value| options[:root] = File.expand_path(value) }
  parser.on('--tests-meta FILE') { |value| options[:tests_meta] = File.expand_path(value) }
end.parse!
raise ArticleContractError, 'unexpected arguments' unless ARGV.empty?

contract = YAML.safe_load_file(options.fetch(:contract))
root = options.fetch(:root)
raise ArticleContractError, 'article contract schema must be 1' unless contract.fetch('schema') == 1

repository = contract.fetch('repository')
unless repository.match?(%r{\A[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\z})
  raise ArticleContractError, "invalid GitHub repository #{repository.inspect}"
end

lock = JSON.parse(File.read(path_within(root, 'flake.lock')))
captures = JSON.parse(File.read(path_within(root, 'captures.json')))
revisions = contract.fetch('revisions')

%w[vpsadmin vpsadminos].each do |input|
  actual = lock.dig('nodes', input, 'locked', 'rev')
  expected = revisions.fetch(input)
  unless actual == expected
    raise ArticleContractError, "#{input} revision differs: expected #{expected}, got #{actual}"
  end
end

unless captures.fetch('vpsadmin_commit') == revisions.fetch('vpsadmin')
  raise ArticleContractError, 'article and capture vpsAdmin revisions differ'
end

workflow = File.read(path_within(root, '.github/workflows/article-runtime.yml'))
workflow_revisions = workflow.scan(
  %r{vpsfreecz/vpsadminos/[^@\s]+@([0-9a-f]{40})}
).flatten.uniq
unless workflow_revisions == [revisions.fetch('vpsadminos')]
  raise ArticleContractError, 'article runtime workflow does not use the pinned vpsAdminOS revision'
end

tests_meta = load_tests_meta(root, options.fetch(:tests_meta))
articles = contract.fetch('articles')
raise ArticleContractError, 'articles must not be empty' unless articles.is_a?(Hash) && !articles.empty?

article_suites = articles.to_h do |article_id, article|
  unless article_id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    raise ArticleContractError, "invalid article ID #{article_id.inspect}"
  end

  [article_id, article.fetch('test').fetch('suite')]
end
unless article_suites.values.uniq.length == article_suites.length
  raise ArticleContractError, 'each article must own a distinct test suite'
end

runtime_inventory = Hash.new { |hash, key| hash[key] = [] }
tests_meta.each do |suite, suite_meta|
  scripts_meta = suite_meta.fetch('testScripts', {})
  unless scripts_meta.is_a?(Hash)
    raise ArticleContractError, "#{suite}: testScripts metadata must be a mapping"
  end

  scripts_meta.each do |script_id, metadata|
    tags = metadata.fetch('tags', [])
    labels = metadata.fetch('labels', {})
    unless tags.is_a?(Array) && labels.is_a?(Hash)
      raise ArticleContractError, "#{suite}##{script_id}: invalid test tags or labels metadata"
    end
    runtime = tags.include?('kb-runtime')
    labeled = labels.key?('kbArticle')
    next unless runtime || labeled

    unless runtime
      raise ArticleContractError, "#{suite}##{script_id} has a kbArticle label but lacks the kb-runtime tag"
    end
    article_id = labels['kbArticle']
    unless article_id
      raise ArticleContractError, "#{suite}##{script_id} lacks the kbArticle label"
    end
    expected_suite = article_suites[article_id]
    unless expected_suite
      raise ArticleContractError, "#{suite}##{script_id} has unknown kbArticle label #{article_id.inspect}"
    end
    unless suite == expected_suite
      raise ArticleContractError, "#{suite}##{script_id} is labeled for #{article_id}, " \
                                  "but that article owns suite #{expected_suite}"
    end

    runtime_inventory[article_id] << [suite, script_id]
  end
end

page_ids = []
article_count = 0
test_count = 0
sample_count = 0

articles.each do |article_id, article|
  test = article.fetch('test')
  suite = test.fetch('suite')
  test_source = path_within(root, test.fetch('source'))
  raise ArticleContractError, "#{article_id}: test source is missing" unless File.file?(test_source)

  suite_meta = tests_meta.fetch(suite) do
    raise ArticleContractError, "#{article_id}: test suite #{suite} is missing from testsMeta"
  end
  scripts_meta = suite_meta.fetch('testScripts')
  script_ids = scripts_meta.keys
  raise ArticleContractError, "#{article_id}: test suite has no scripts" if script_ids.empty?
  discovered_scripts = runtime_inventory.fetch(article_id, []).map(&:last)
  unless discovered_scripts.sort == script_ids.sort
    raise ArticleContractError, "#{article_id}: registered suite and kb-runtime inventory differ"
  end
  scripts_meta.each do |script_id, metadata|
    unless metadata.fetch('tags').include?('kb-runtime')
      raise ArticleContractError, "#{article_id}: #{suite}##{script_id} lacks the kb-runtime tag"
    end
    unless metadata.fetch('labels').fetch('kbArticle', nil) == article_id
      raise ArticleContractError, "#{article_id}: #{suite}##{script_id} has the wrong kbArticle label"
    end
  end

  pages = article.fetch('pages')
  unless pages.keys.sort == %w[cs en]
    raise ArticleContractError, "#{article_id}: pages must contain exactly cs and en"
  end

  page_sources = {}
  page_sections = {}
  pages.each do |language, page|
    id = page.fetch('id')
    page_ids << id
    source_path = path_within(root, page.fetch('source'))
    raise ArticleContractError, "#{article_id}: #{language}: page source is missing" unless File.file?(source_path)

    source = File.read(source_path, encoding: Encoding::UTF_8)
    counterpart = page.fetch('counterpart')
    unless source.start_with?("<page>#{counterpart}</page>\n")
      raise ArticleContractError, "#{article_id}: #{language}: counterpart mapping differs"
    end

    source_url = "https://github.com/#{repository}/blob/master/#{page.fetch('source')}"
    test_url = "https://github.com/#{repository}/blob/master/#{test.fetch('source')}"
    marker_starts = source.scan(/<kb-managed\b/)
    unless marker_starts.length == 1
      raise ArticleContractError,
            "#{article_id}: #{language}: expected exactly one managed-page marker"
    end

    expected_prefix = "<page>#{counterpart}</page>\n\n" \
                      "#{managed_marker(source_url, test_url)}\n\n"
    unless source.start_with?(expected_prefix)
      raise ArticleContractError,
            "#{article_id}: #{language}: managed-page marker is misplaced or differs from the registry"
    end

    page_sources[language] = source
    page_sections[language] = sections(source)
  end

  unless pages.fetch('cs').fetch('counterpart') == pages.fetch('en').fetch('id') &&
         pages.fetch('en').fetch('counterpart') == pages.fetch('cs').fetch('id')
    raise ArticleContractError, "#{article_id}: counterpart mapping is not reciprocal"
  end

  samples = article.fetch('samples', {})
  sample_ids = samples.keys
  sample_display_sources = {}
  samples.each do |sample_id, sample|
    code_language = sample.fetch('language', 'bash')
    unless code_language.is_a?(String) && code_language.match?(/\A[a-zA-Z0-9_+-]+\z/)
      raise ArticleContractError, "#{article_id}: #{sample_id}: invalid code language"
    end

    path = path_within(root, sample.fetch('path'))
    raise ArticleContractError, "#{article_id}: #{sample_id}: sample file is missing" unless File.file?(path)

    actual = Digest::SHA256.file(path).hexdigest
    unless actual == sample.fetch('sha256')
      raise ArticleContractError, "#{article_id}: #{sample_id}: sample SHA-256 differs"
    end

    runtime_source = File.read(path, encoding: Encoding::UTF_8)
    sample_display_sources[sample_id] = display_sources(
      article_id,
      sample_id,
      sample,
      runtime_source,
      code_language
    )

    unknown_tests = sample.fetch('tests') - script_ids
    unless unknown_tests.empty?
      raise ArticleContractError, "#{article_id}: #{sample_id}: unknown tests #{unknown_tests.join(', ')}"
    end
  end

  used_tests = []
  used_samples = []
  sample_tests = Hash.new { |hash, key| hash[key] = [] }
  headings = Hash.new { |hash, key| hash[key] = [] }
  sections_contract = article.fetch('sections')
  raise ArticleContractError, "#{article_id}: sections must not be empty" if sections_contract.empty?

  sections_contract.each do |section_id, section|
    claims = section.fetch('claims')
    raise ArticleContractError, "#{article_id}: #{section_id}: claims must not be empty" if claims.empty?
    unless claims.uniq.length == claims.length
      raise ArticleContractError, "#{article_id}: #{section_id}: claims contain duplicates"
    end

    section_tests = section.fetch('tests')
    section_samples = section.fetch('samples')
    unknown_tests = section_tests - script_ids
    unknown_samples = section_samples - sample_ids
    unless unknown_tests.empty?
      raise ArticleContractError, "#{article_id}: #{section_id}: unknown tests #{unknown_tests.join(', ')}"
    end
    unless unknown_samples.empty?
      raise ArticleContractError, "#{article_id}: #{section_id}: unknown samples #{unknown_samples.join(', ')}"
    end

    localizations = section.fetch('localizations')
    unless localizations.keys.sort == %w[cs en]
      raise ArticleContractError, "#{article_id}: #{section_id}: localizations must contain exactly cs and en"
    end
    localizations.each do |language, localization|
      heading = localization.fetch('heading')
      headings[language] << heading
      body = page_sections.fetch(language).fetch(heading) do
        raise ArticleContractError, "#{article_id}: #{language}: missing section #{heading}"
      end
      fingerprint = Digest::SHA256.hexdigest(normalize(body))
      unless fingerprint == localization.fetch('fingerprint')
        raise ArticleContractError, "#{article_id}: #{language}: section fingerprint differs for #{heading}"
      end

      section_samples.each do |sample_id|
        sample_contract = samples.fetch(sample_id)
        sample = sample_display_sources.fetch(sample_id).fetch(language).strip
        code_language = sample_contract.fetch('language', 'bash')
        unless body.include?("<code #{code_language}>\n#{sample}\n</code>")
          raise ArticleContractError, "#{article_id}: #{language}: #{heading}: exact sample #{sample_id} is missing"
        end
      end
    end

    section_samples.each { |sample_id| sample_tests[sample_id].concat(section_tests) }
    used_tests.concat(section_tests)
    used_samples.concat(section_samples)
  end

  %w[cs en].each do |language|
    unless page_sections.fetch(language).keys == headings.fetch(language)
      raise ArticleContractError, "#{article_id}: #{language}: section heading set or order differs"
    end
  end
  unless used_tests.uniq.sort == script_ids.sort
    raise ArticleContractError, "#{article_id}: every runtime test must be bound to a section"
  end
  unless used_samples.uniq.sort == sample_ids.sort
    raise ArticleContractError, "#{article_id}: every executable sample must be bound to a section"
  end
  samples.each do |sample_id, sample|
    outside_sections = sample.fetch('tests') - sample_tests.fetch(sample_id).uniq
    unless outside_sections.empty?
      raise ArticleContractError, "#{article_id}: #{sample_id}: tests are outside its bound sections"
    end
  end

  article.fetch('captures', []).each do |capture_id|
    asset = captures.fetch('assets').find { |item| item.fetch('id') == capture_id }
    raise ArticleContractError, "#{article_id}: missing capture #{capture_id}" unless asset

    expected = pages.to_h { |language, page| [language, [page.fetch('id')]] }
    actual = asset.fetch('variants').to_h do |language, variant|
      [language, variant.dig('wiki', 'source_pages')]
    end
    unless actual == expected
      raise ArticleContractError, "#{article_id}: #{capture_id}: page bindings differ"
    end
  end

  article_count += 1
  test_count += script_ids.length
  sample_count += sample_ids.length
end

unless page_ids.uniq.length == page_ids.length
  raise ArticleContractError, 'duplicate managed page IDs'
end

puts "Valid article contract: #{article_count} articles, #{page_ids.length} pages, " \
     "#{test_count} tests, #{sample_count} executable samples"
