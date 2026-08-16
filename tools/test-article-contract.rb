#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class ArticleContractCheckerTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CHECKER = File.join(ROOT, 'tools/check-article-contract.rb')
  CONTRACT = File.join(ROOT, 'contract/articles.yml')

  def self.tests_meta
    @tests_meta ||= begin
      if ENV['ARTICLE_TESTS_META']
        JSON.parse(File.read(ENV.fetch('ARTICLE_TESTS_META')))
      else
        output, error, status = Open3.capture3(
          'nix', 'eval', '--json', '.#testsMeta.x86_64-linux',
          chdir: ROOT
        )
        raise error unless status.success?

        JSON.parse(output)
      end
    end
  end

  def test_current_contract_is_valid
    _output, error, status = run_checker(YAML.safe_load_file(CONTRACT), self.class.tests_meta)

    assert(status.success?, error)
  end

  def test_article_id_is_not_hard_coded
    contract = YAML.safe_load_file(CONTRACT)
    article = contract.fetch('articles').delete('kvm')
    contract.fetch('articles')['virtualization'] = article
    metadata = Marshal.load(Marshal.dump(self.class.tests_meta))
    metadata.fetch('kb/kvm').fetch('testScripts').each_value do |script|
      script.fetch('labels')['kbArticle'] = 'virtualization'
    end

    _output, error, status = run_checker(contract, metadata)

    assert(status.success?, error)
  end

  def test_revision_drift_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.fetch('revisions')['vpsadminos'] = '0' * 40
    end

    refute(status.success?)
    assert_match(/vpsadminos revision differs/, error)
  end

  def test_sample_drift_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'kvm', 'samples', 'install-libvirt')['sha256'] = '0' * 64
    end

    refute(status.success?)
    assert_match(/install-libvirt: sample SHA-256 differs/, error)
  end

  def test_invalid_sample_code_language_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'guix', 'samples', 'deploy-system')['language'] = 'scheme bad'
    end

    refute(status.success?)
    assert_match(/deploy-system: invalid code language/, error)
  end

  def test_display_variants_require_both_languages
    _output, error, status = check_mutated_contract do |contract|
      sample = contract.dig('articles', 'guix', 'samples', 'reconfigure-system')
      sample.fetch('display_variants').delete('en')
    end

    refute(status.success?)
    assert_match(/display variants must contain exactly cs and en/, error)
  end

  def test_human_readable_comments_require_display_variants
    _output, error, status = check_mutated_contract do |contract|
      sample = contract.dig('articles', 'guix', 'samples', 'reconfigure-system')
      sample.delete('display_variants')
    end

    refute(status.success?)
    assert_match(/display variants must contain exactly cs and en/, error)
  end

  def test_display_variant_must_bind_every_human_readable_comment
    _output, error, status = check_mutated_contract do |contract|
      comments = contract.dig(
        'articles', 'guix', 'samples', 'reconfigure-system',
        'display_variants', 'cs', 'comments'
      )
      comments.delete(4)
    end

    refute(status.success?)
    assert_match(/missing display comment for line 4/, error)
  end

  def test_display_variant_cannot_override_a_shebang
    _output, error, status = check_mutated_contract do |contract|
      comments = contract.dig(
        'articles', 'guix', 'samples', 'reconfigure-system',
        'display_variants', 'cs', 'comments'
      )
      comments[1] = '#!/bin/sh'
    end

    refute(status.success?)
    assert_match(/line 1 is not a human-readable comment/, error)
  end

  def test_display_variant_cannot_override_a_tool_directive
    _output, error, status = check_mutated_contract do |contract|
      comments = contract.dig(
        'articles', 'guix', 'samples', 'reconfigure-system',
        'display_variants', 'cs', 'comments'
      )
      comments[6] = '# shellcheck disable=SC1090'
    end

    refute(status.success?)
    assert_match(/line 6 is not a human-readable comment/, error)
  end

  def test_display_variant_cannot_override_an_executable_line
    _output, error, status = check_mutated_contract do |contract|
      comments = contract.dig(
        'articles', 'guix', 'samples', 'reconfigure-system',
        'display_variants', 'cs', 'comments'
      )
      comments[5] = 'export GUIX_PROFILE=/tmp/profile'
    end

    refute(status.success?)
    assert_match(/line 5 is not a human-readable comment/, error)
  end

  def test_display_variant_must_preserve_comment_line_structure
    _output, error, status = check_mutated_contract do |contract|
      comments = contract.dig(
        'articles', 'guix', 'samples', 'reconfigure-system',
        'display_variants', 'cs', 'comments'
      )
      comments[4] = '  # Použij revizi Guixu.'
    end

    refute(status.success?)
    assert_match(/comment line structure differs at line 4/, error)
  end

  def test_human_readable_display_comments_must_be_localized
    _output, error, status = check_mutated_contract do |contract|
      variants = contract.dig(
        'articles', 'guix', 'samples', 'reconfigure-system', 'display_variants'
      )
      variants.fetch('cs').fetch('comments')[4] = variants.fetch('en').fetch('comments').fetch(4)
    end

    refute(status.success?)
    assert_match(/human-readable comment is not localized at line 4/, error)
  end

  def test_page_must_include_its_matching_language_display_variant
    _output, error, status = check_mutated_contract do |contract|
      variants = contract.dig(
        'articles', 'guix', 'samples', 'reconfigure-system', 'display_variants'
      )
      variants['cs'], variants['en'] = variants.fetch('en'), variants.fetch('cs')
    end

    refute(status.success?)
    assert_match(/guix: cs: Úprava konfigurace: exact sample reconfigure-system is missing/, error)
  end

  def test_section_drift_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig(
        'articles', 'kvm', 'sections', 'libvirt', 'localizations', 'cs'
      )['fingerprint'] = '0' * 64
    end

    refute(status.success?)
    assert_match(/section fingerprint differs/, error)
  end

  def test_unknown_test_binding_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'kvm', 'sections', 'libvirt')['tests'] = ['missing']
    end

    refute(status.success?)
    assert_match(/unknown tests missing/, error)
  end

  def test_unknown_article_label_is_rejected
    metadata = Marshal.load(Marshal.dump(self.class.tests_meta))
    metadata.dig('kb/kvm', 'testScripts', 'storage', 'labels')['kbArticle'] = 'other'

    _output, error, status = run_checker(YAML.safe_load_file(CONTRACT), metadata)

    refute(status.success?)
    assert_match(/storage has unknown kbArticle label "other"/, error)
  end

  def test_runtime_script_without_an_article_label_is_rejected
    metadata = Marshal.load(Marshal.dump(self.class.tests_meta))
    metadata.dig('kb/kvm', 'testScripts', 'storage', 'labels').delete('kbArticle')

    _output, error, status = run_checker(YAML.safe_load_file(CONTRACT), metadata)

    refute(status.success?)
    assert_match(/storage lacks the kbArticle label/, error)
  end

  def test_article_labeled_script_without_the_runtime_tag_is_rejected
    metadata = Marshal.load(Marshal.dump(self.class.tests_meta))
    metadata.dig('kb/kvm', 'testScripts', 'storage', 'tags').delete('kb-runtime')

    _output, error, status = run_checker(YAML.safe_load_file(CONTRACT), metadata)

    refute(status.success?)
    assert_match(/storage has a kbArticle label but lacks the kb-runtime tag/, error)
  end

  def test_article_label_in_an_unregistered_suite_is_rejected
    metadata = Marshal.load(Marshal.dump(self.class.tests_meta))
    script = Marshal.load(Marshal.dump(metadata.dig('kb/kvm', 'testScripts', 'storage')))
    metadata['kb/unregistered'] = { 'testScripts' => { 'external' => script } }

    _output, error, status = run_checker(YAML.safe_load_file(CONTRACT), metadata)

    refute(status.success?)
    assert_match(/kb\/unregistered#external is labeled for kvm/, error)
    assert_match(/article owns suite kb\/kvm/, error)
  end

  def test_invalid_repository_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract['repository'] = 'https://github.com/vpsfreecz/vpsfree-kb-contracts'
    end

    refute(status.success?)
    assert_match(/article repository must be vpsfreecz\/vpsfree-kb-contracts/, error)
  end

  def test_other_valid_repository_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract['repository'] = 'vpsfreecz/other-contracts'
    end

    refute(status.success?)
    assert_match(/article repository must be vpsfreecz\/vpsfree-kb-contracts/, error)
  end

  def test_full_source_url_is_rejected
    _output, error, status = check_czech_source do |_marker, relative_path, test_pattern|
      marker = managed_marker(
        "https://github.com/vpsfreecz/vpsfree-kb-contracts/blob/master/#{relative_path}",
        test_pattern
      )
      "<page>manuals:vps:kvm</page>\n\n#{marker}\n"
    end

    refute(status.success?)
    assert_match(/managed-page marker is misplaced or differs/, error)
  end

  def test_test_source_path_is_rejected_as_marker_pattern
    _output, error, status = check_czech_source do |_marker, relative_path, _test_pattern|
      marker = managed_marker(relative_path, 'tests/suite/kb/kvm.nix')
      "<page>manuals:vps:kvm</page>\n\n#{marker}\n"
    end

    refute(status.success?)
    assert_match(/managed-page marker is misplaced or differs/, error)
  end

  def test_test_pattern_must_select_every_script
    _output, error, status = check_czech_source do |_marker, relative_path, _test_pattern|
      marker = managed_marker(relative_path, 'kb/kvm#storage')
      "<page>manuals:vps:kvm</page>\n\n#{marker}\n"
    end

    refute(status.success?)
    assert_match(/managed-page marker is misplaced or differs/, error)
  end

  def test_unsafe_page_source_path_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'kvm', 'pages', 'cs')['source'] = '../page.txt'
    end

    refute(status.success?)
    assert_match(/page source must be a safe repository-relative path/, error)
  end

  def test_unsafe_test_source_path_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'kvm', 'test')['source'] = '/tmp/kvm.nix'
    end

    refute(status.success?)
    assert_match(/test source must be a repository-relative path/, error)
  end

  def test_test_source_must_be_derived_from_the_suite
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'kvm', 'test')['source'] = 'tests/suite/kb/gre.nix'
    end

    refute(status.success?)
    assert_match(/kvm: test source must be tests\/suite\/kb\/kvm\.nix/, error)
  end

  def test_invalid_test_suite_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'kvm', 'test')['suite'] = 'kb/kvm#storage'
    end

    refute(status.success?)
    assert_match(/test suite must be a test-runner suite name/, error)
  end

  def test_empty_test_suite_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.dig('articles', 'kvm', 'test')['suite'] = ''
    end

    refute(status.success?)
    assert_match(/test suite must be a test-runner suite name/, error)
  end

  def test_missing_managed_page_marker_is_rejected
    _output, error, status = check_czech_source do |_marker|
      "<page>manuals:vps:kvm</page>\n\n====== Test ======\n"
    end

    refute(status.success?)
    assert_match(/expected exactly one managed-page marker/, error)
  end

  def test_managed_page_marker_below_the_title_is_rejected
    _output, error, status = check_czech_source do |marker|
      "<page>manuals:vps:kvm</page>\n\n====== Test ======\n\n#{marker}\n"
    end

    refute(status.success?)
    assert_match(/managed-page marker is misplaced/, error)
  end

  def test_duplicate_managed_page_markers_are_rejected
    _output, error, status = check_czech_source do |marker|
      "<page>manuals:vps:kvm</page>\n\n#{marker}\n\n#{marker}\n"
    end

    refute(status.success?)
    assert_match(/expected exactly one managed-page marker/, error)
  end

  def test_additional_malformed_managed_page_marker_is_rejected
    _output, error, status = check_czech_source do |marker|
      "<page>manuals:vps:kvm</page>\n\n#{marker}\n\n<kb-managed source=\"invalid\">\n"
    end

    refute(status.success?)
    assert_match(/expected exactly one managed-page marker/, error)
  end

  private

  def managed_marker(source, test)
    <<~MARKER.chomp
      <kb-managed
        source="#{source}"
        test="#{test}"
      />
    MARKER
  end

  def check_czech_source
    Dir.mktmpdir('.article-contract-', ROOT) do |dir|
      contract = YAML.safe_load_file(CONTRACT)
      source_path = File.join(dir, 'page.txt')
      relative_path = source_path.delete_prefix("#{ROOT}/")
      contract.dig('articles', 'kvm', 'pages', 'cs')['source'] = relative_path
      suite = contract.dig('articles', 'kvm', 'test', 'suite')
      marker = managed_marker(relative_path, "#{suite}#*")
      File.write(source_path, yield(marker, relative_path, "#{suite}#*"))
      run_checker(contract, self.class.tests_meta)
    end
  end

  def check_mutated_contract
    contract = YAML.safe_load_file(CONTRACT)
    yield contract
    run_checker(contract, self.class.tests_meta)
  end

  def run_checker(contract, tests_meta)
    Dir.mktmpdir do |dir|
      contract_path = File.join(dir, 'articles.yml')
      metadata_path = File.join(dir, 'tests-meta.json')
      File.write(contract_path, YAML.dump(contract))
      File.write(metadata_path, JSON.generate(tests_meta))
      Open3.capture3(
        RbConfig.ruby,
        CHECKER,
        '--contract', contract_path,
        '--root', ROOT,
        '--tests-meta', metadata_path
      )
    end
  end
end
