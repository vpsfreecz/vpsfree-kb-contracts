#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'yaml'
require_relative 'kb_navigation_discovery'

options = {
  navigation: File.expand_path('../contract/navigation.yml', __dir__),
  annotations: File.expand_path('../contract/kb-annotations.yml', __dir__),
  inventory: File.expand_path('../contract/kb-navigation-inventory.yml', __dir__)
}
OptionParser.new do |parser|
  parser.on('--navigation FILE') { |value| options[:navigation] = File.expand_path(value) }
  parser.on('--annotations FILE') { |value| options[:annotations] = File.expand_path(value) }
  parser.on('--inventory FILE') { |value| options[:inventory] = File.expand_path(value) }
  parser.on('--candidate-index FILE') { |value| options[:candidate_index] = File.expand_path(value) }
  parser.on('--source-index FILE') { |value| options[:source_index] = File.expand_path(value) }
end.parse!

navigation = YAML.safe_load_file(options.fetch(:navigation))
annotations = YAML.safe_load_file(options.fetch(:annotations))
abort 'annotation contract schema must be 1' unless annotations.fetch('schema') == 1

languages = navigation.fetch('languages')
paths = navigation.fetch('paths')
paths_by_id = paths.to_h { |path| [path.fetch('id'), path] }

validate_entry = lambda do |entry, kind|
  language = entry.fetch('language')
  page = entry.fetch('page')
  path_id = entry.fetch('path')
  abort "#{kind}: unknown language #{language}" unless languages.include?(language)
  path = paths_by_id[path_id]
  abort "#{kind}: unknown path #{path_id}" unless path
  unless path.fetch('pages').fetch(language).include?(page)
    abort "#{kind}: #{language}:#{page} is not affected by #{path_id}"
  end
end

bindings = annotations.fetch('bindings')
exceptions = annotations.fetch('exceptions')
bindings.each { |entry| validate_entry.call(entry, 'binding') }
exceptions.each do |entry|
  validate_entry.call(entry, 'exception')
  abort 'annotation exception reason must not be blank' if entry.fetch('reason').strip.empty?
end

binding_keys = bindings.map { |item| item.values_at('language', 'page', 'path') }
exception_keys = exceptions.map { |item| item.values_at('language', 'page', 'path') }
abort 'duplicate KB annotation bindings' unless binding_keys.uniq.length == binding_keys.length
abort 'duplicate KB annotation exceptions' unless exception_keys.uniq.length == exception_keys.length
overlap = binding_keys & exception_keys
abort "annotation bindings overlap exceptions: #{overlap.inspect}" unless overlap.empty?

expected_keys = paths.flat_map do |path|
  languages.flat_map do |language|
    path.fetch('pages').fetch(language).map { |page| [language, page, path.fetch('id')] }
  end
end.uniq.sort
covered_keys = (binding_keys + exception_keys).uniq.sort
unless covered_keys == expected_keys
  missing = expected_keys - covered_keys
  extra = covered_keys - expected_keys
  abort "annotation inventory mismatch; missing=#{missing.inspect}, extra=#{extra.inspect}"
end

if options[:candidate_index]
  abort '--source-index is required with --candidate-index' unless options[:source_index]
  index_path = options.fetch(:candidate_index)
  index = JSON.parse(File.read(index_path))
  root = File.dirname(index_path)
  source_index_path = options.fetch(:source_index)
  source_index = JSON.parse(File.read(source_index_path))
  source_root = File.dirname(source_index_path)
  inventory = YAML.safe_load_file(options.fetch(:inventory))
  abort 'KB navigation inventory schema must be 1' unless inventory.fetch('schema') == 1
  candidate_pages = index.fetch('pages')
  source_pages = source_index.flat_map do |language, entries|
    entries.map { |entry| entry.merge('language' => language) }
  end
  candidate_keys = candidate_pages.map { |page| page.values_at('language', 'id') }
  source_keys = source_pages.map { |page| page.values_at('language', 'id') }
  inventory_keys = inventory.fetch('page_ids').flat_map do |language, page_ids|
    page_ids.map { |page_id| [language, page_id] }
  end
  abort 'duplicate candidate page IDs' unless candidate_keys.uniq.length == candidate_keys.length
  abort 'duplicate candidate page files' unless candidate_pages.map { |page| page.fetch('file') }.uniq.length == candidate_pages.length
  abort 'duplicate source page IDs' unless source_keys.uniq.length == source_keys.length
  abort 'duplicate source page files' unless source_pages.map { |page| page.fetch('file') }.uniq.length == source_pages.length
  unless candidate_keys.sort == inventory_keys.sort && source_keys.sort == inventory_keys.sort
    abort "page identity inventory differs; expected=#{inventory_keys.sort.inspect}, " \
          "candidate=#{candidate_keys.sort.inspect}, source=#{source_keys.sort.inspect}"
  end
  candidate_paragraphs = candidate_pages.to_h do |page|
    content = File.read(File.join(root, page.fetch('file')))
    [[page.fetch('language'), page.fetch('id')], KbNavigationDiscovery.paragraphs(content)]
  end
  candidate_pages_by_key = candidate_pages.to_h do |page|
    [page.values_at('language', 'id'), page]
  end
  actual = Hash.new(0)
  tag_pattern = /<vpsadmin-nav\s+id="([a-z][a-z0-9.-]*)">(.*?)<\/vpsadmin-nav>/m

  index.fetch('pages').each do |page|
    content = File.read(File.join(root, page.fetch('file')))
    semantic_content = KbNavigationDiscovery.semantic_content(content)
    matches = semantic_content.scan(tag_pattern)
    unless semantic_content.scan('<vpsadmin-nav').length == matches.length &&
           semantic_content.scan('</vpsadmin-nav>').length == matches.length
      abort "#{page.fetch('language')}:#{page.fetch('id')}: malformed annotation tags"
    end

    matches.each do |path_id, body|
      abort "unknown annotation path #{path_id}" unless paths_by_id.key?(path_id)
      abort "#{path_id}: annotation body must not be blank" if body.strip.empty?
      actual[[page.fetch('language'), page.fetch('id'), path_id]] += 1
    end
  end

  expected = bindings.to_h do |entry|
    [entry.values_at('language', 'page', 'path'), entry.fetch('count')]
  end
  unless actual == expected
    abort "candidate annotation counts differ; expected=#{expected.inspect}, actual=#{actual.inspect}"
  end

  discoveries = source_pages.flat_map do |page|
    content = if page['missing'] == true
                candidate_page = candidate_pages_by_key.fetch(page.values_at('language', 'id'))
                File.read(File.join(root, candidate_page.fetch('file')))
              else
                File.read(File.join(source_root, page.fetch('file')))
              end
    KbNavigationDiscovery.discover(
      language: page.fetch('language'),
      page: page.fetch('id'),
      content:
    )
  end
  discovered_by_id = discoveries.to_h { |entry| [entry.fetch('id'), entry] }
  inventory_entries = inventory.fetch('discoveries')
  inventory_by_id = inventory_entries.to_h { |entry| [entry.fetch('id'), entry] }
  abort 'duplicate discovered navigation IDs' unless discovered_by_id.length == discoveries.length
  abort 'duplicate inventoried navigation IDs' unless inventory_by_id.length == inventory_entries.length

  unless discovered_by_id.keys.sort == inventory_by_id.keys.sort
    missing = discovered_by_id.keys - inventory_by_id.keys
    stale = inventory_by_id.keys - discovered_by_id.keys
    abort "independent navigation inventory mismatch; unclassified=#{missing.inspect}, stale=#{stale.inspect}"
  end

  structural_replacements = index.fetch('annotations', []).select do |annotation|
    annotation['before'] && annotation['replacement'] &&
      KbNavigationDiscovery.paragraphs(annotation.fetch('before')).length > 1
  end
  discoveries.each do |discovery|
    inventoried = inventory_by_id.fetch(discovery.fetch('id'))
    %w[language page paragraph text].each do |key|
      abort "#{discovery.fetch('id')}: inventory #{key} drift" unless inventoried.fetch(key) == discovery.fetch(key)
    end

    paragraphs = candidate_paragraphs.fetch(
      [discovery.fetch('language'), discovery.fetch('page')]
    )
    candidate_matches = paragraphs.each_index.select do |paragraph_index|
      KbNavigationDiscovery.normalize(paragraphs.fetch(paragraph_index)) == discovery.fetch('text')
    end
    if candidate_matches.empty?
      replaced = structural_replacements.any? do |annotation|
        next false unless annotation.values_at('language', 'page') ==
                          discovery.values_at('language', 'page')

        KbNavigationDiscovery.paragraphs(annotation.fetch('before')).any? do |paragraph|
          replacement_text = KbNavigationDiscovery.normalize(paragraph)
          !replacement_text.empty? &&
            (replacement_text.include?(discovery.fetch('text')) ||
             discovery.fetch('text').include?(replacement_text))
        end
      end
      abort "#{discovery.fetch('id')}: source navigation paragraph disappeared without a replacement" unless replaced

      next
    end
    abort "#{discovery.fetch('id')}: source navigation paragraph is ambiguous in candidate" \
      unless candidate_matches.length == 1

    expected_paths = inventoried.fetch('paths', []).sort
    expected_paths.each do |path_id|
      path = paths_by_id[path_id]
      abort "#{discovery.fetch('id')}: unknown inventoried path #{path_id}" unless path
      unless path.fetch('pages').fetch(discovery.fetch('language')).include?(discovery.fetch('page'))
        abort "#{discovery.fetch('id')}: inventoried path #{path_id} does not affect this page"
      end
    end

    candidate_paragraph = paragraphs.fetch(candidate_matches.first)
    actual_paths = candidate_paragraph.scan(tag_pattern).map(&:first).sort
    reason = inventoried['reason']
    if reason
      abort "#{discovery.fetch('id')}: exception reason must not be blank" unless reason.is_a?(String) && !reason.strip.empty?
      abort "#{discovery.fetch('id')}: excepted source paragraph contains candidate tags" unless actual_paths.empty?
    elsif expected_paths.empty?
      abort "#{discovery.fetch('id')}: discovery needs paths or an exception reason"
    elsif expected_paths != actual_paths
      abort "#{discovery.fetch('id')}: inventoried paths differ; expected=#{expected_paths.inspect}, actual=#{actual_paths.inspect}"
    end
  end

  candidate_discovery_locations = candidate_pages.flat_map do |page|
    content = File.read(File.join(root, page.fetch('file')))
    KbNavigationDiscovery.discover(
      language: page.fetch('language'),
      page: page.fetch('id'),
      content:
    ).map { |entry| entry.values_at('language', 'page', 'paragraph') }
  end
  tagged_locations = candidate_pages.flat_map do |page|
    candidate_paragraphs.fetch([page.fetch('language'), page.fetch('id')]).each_with_index.filter_map do |paragraph, paragraph_index|
      if KbNavigationDiscovery.semantic_content(paragraph).include?('<vpsadmin-nav')
        [page.fetch('language'), page.fetch('id'), paragraph_index]
      end
    end
  end
  missed = tagged_locations - candidate_discovery_locations
  abort "independent scanner missed annotated paragraphs: #{missed.inspect}" unless missed.empty?
end

puts "Valid KB annotation inventory: #{bindings.length} bindings, #{exceptions.length} exceptions"
