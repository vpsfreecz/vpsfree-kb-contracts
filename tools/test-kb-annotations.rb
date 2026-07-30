#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative 'kb_navigation_discovery'

class KbAnnotationsCheckerTest < Minitest::Test
  CHECKER = File.expand_path('check-kb-annotations.rb', __dir__)

  def test_valid_candidate
    _out, error, status = run_checker

    assert(status.success?, error)
  end

  def test_missing_candidate_annotation_is_rejected
    _out, error, status = run_checker(body: 'Navigation without a tag')

    refute(status.success?)
    assert_match(/candidate annotation counts differ/, error)
  end

  def test_unknown_candidate_path_is_rejected
    body = '<vpsadmin-nav id="missing.path">Navigation</vpsadmin-nav>'
    _out, error, status = run_checker(body:)

    refute(status.success?)
    assert_match(/unknown annotation path missing\.path/, error)
  end

  def test_literal_and_code_block_examples_are_not_annotations
    body = <<~DOKUWIKI
      %%<vpsadmin-nav>%%

      <code>
      <vpsadmin-nav id="missing.path">Example</vpsadmin-nav>
      </code>

      <vpsadmin-nav id="member.public-keys.open">vpsAdmin -> Edit profile</vpsadmin-nav>
    DOKUWIKI
    _out, error, status = run_checker(body:)

    assert(status.success?, error)
  end

  def test_every_affected_page_requires_binding_or_exception
    _out, error, status = run_checker(bindings: [], body: 'No annotation')

    refute(status.success?)
    assert_match(/annotation inventory mismatch/, error)
  end

  def test_independently_discovered_navigation_requires_classification
    body = '<vpsadmin-nav id="member.public-keys.open">vpsAdmin -> Edit profile</vpsadmin-nav>'
    _out, error, status = run_checker(body:, inventory_discoveries: [])

    refute(status.success?)
    assert_match(/independent navigation inventory mismatch/, error)
  end

  def test_duplicate_page_cannot_replace_an_omitted_identity
    _out, error, status = run_checker(duplicate_candidate: true)

    refute(status.success?)
    assert_match(/duplicate candidate page IDs/, error)
  end

  def test_guarded_new_page_is_discovered_from_the_candidate
    _out, error, status = run_checker(missing_source: true)

    assert(status.success?, error)
  end

  def test_structural_replacement_can_remove_an_obsolete_navigation_path
    source_body = 'vpsAdmin -> Advanced e-mail settings'
    inventory = KbNavigationDiscovery.discover(
      language: 'cs',
      page: 'navody:test',
      content: source_body
    )
    inventory.first['paths'] = ['removed.path']
    replacement = {
      'language' => 'cs',
      'page' => 'navody:test',
      'before' => "#{source_body}\n\nObsolete screenshot",
      'replacement' => 'vpsAdmin -> Edit profile'
    }

    _out, error, status = run_checker(
      candidate_annotations: [replacement],
      inventory_discoveries: inventory,
      source_body:
    )

    assert(status.success?, error)
  end

  private

  def run_checker(
    bindings: [binding],
    body: '<vpsadmin-nav id="member.public-keys.open">vpsAdmin -> Edit profile</vpsadmin-nav>',
    source_body: nil,
    inventory_discoveries: nil,
    candidate_annotations: nil,
    duplicate_candidate: false,
    missing_source: false
  )
    Dir.mktmpdir do |dir|
      navigation = {
        'languages' => %w[cs en],
        'paths' => [
          {
            'id' => 'member.public-keys.open',
            'pages' => { 'cs' => ['navody:test'], 'en' => [] }
          }
        ]
      }
      annotations = { 'schema' => 1, 'bindings' => bindings, 'exceptions' => [] }
      candidate = {
        'pages' => [
          { 'language' => 'cs', 'id' => 'navody:test', 'file' => 'cs/navody/test.txt' }
        ]
      }
      candidate['annotations'] = candidate_annotations if candidate_annotations
      candidate['pages'] << candidate['pages'].first.dup if duplicate_candidate
      source_body ||= body.gsub(%r{</?vpsadmin-nav(?:\s+[^>]*)?>}, '')
      source = {
        'cs' => [
          { 'id' => 'navody:test', 'file' => 'cs/navody/test.txt' }
        ],
        'en' => []
      }
      source.fetch('cs').first['missing'] = true if missing_source
      navigation_path = File.join(dir, 'navigation.yml')
      annotations_path = File.join(dir, 'annotations.yml')
      candidate_path = File.join(dir, 'index.json')
      source_path = File.join(dir, 'source-index.json')
      inventory_path = File.join(dir, 'inventory.yml')
      page_path = File.join(dir, 'cs/navody/test.txt')
      source_page_path = File.join(dir, 'source/cs/navody/test.txt')
      FileUtils.mkdir_p(File.dirname(page_path))
      FileUtils.mkdir_p(File.dirname(source_page_path))
      File.write(navigation_path, YAML.dump(navigation))
      File.write(annotations_path, YAML.dump(annotations))
      File.write(candidate_path, JSON.dump(candidate))
      File.write(source_path, JSON.dump(source))
      File.write(page_path, body)
      File.write(source_page_path, missing_source ? '' : source_body)
      source['cs'][0]['file'] = 'source/cs/navody/test.txt'
      File.write(source_path, JSON.dump(source))
      discoveries = inventory_discoveries || KbNavigationDiscovery.discover(
        language: 'cs',
        page: 'navody:test',
        content: missing_source ? body : source_body
      )
      candidate_paths = KbNavigationDiscovery.semantic_content(body)
                                             .scan(/<vpsadmin-nav\s+id="([a-z][a-z0-9.-]*)">/)
                                             .flatten
      discoveries.each do |entry|
        entry['paths'] = candidate_paths if !candidate_paths.empty? && !entry.key?('paths')
      end
      File.write(
        inventory_path,
        YAML.dump(
          'schema' => 1,
          'page_ids' => { 'cs' => ['navody:test'], 'en' => [] },
          'discoveries' => discoveries
        )
      )

      Open3.capture3(
        RbConfig.ruby,
        CHECKER,
        '--navigation', navigation_path,
        '--annotations', annotations_path,
        '--inventory', inventory_path,
        '--candidate-index', candidate_path,
        '--source-index', source_path
      )
    end
  end

  def binding
    {
      'language' => 'cs',
      'page' => 'navody:test',
      'path' => 'member.public-keys.open',
      'count' => 1
    }
  end
end
