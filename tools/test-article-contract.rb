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

  def test_repository_link_drift_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract['repository'] = 'vpsfreecz/different-repository'
    end

    refute(status.success?)
    assert_match(/managed-page marker is misplaced or differs/, error)
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

  def check_czech_source
    Dir.mktmpdir('.article-contract-', ROOT) do |dir|
      contract = YAML.safe_load_file(CONTRACT)
      source_path = File.join(dir, 'page.txt')
      relative_path = source_path.delete_prefix("#{ROOT}/")
      contract.dig('articles', 'kvm', 'pages', 'cs')['source'] = relative_path
      repository = contract.fetch('repository')
      test_source = contract.dig('articles', 'kvm', 'test', 'source')
      marker = <<~MARKER.chomp
        <kb-managed
          source="https://github.com/#{repository}/blob/master/#{relative_path}"
          test="https://github.com/#{repository}/blob/master/#{test_source}"
        />
      MARKER
      File.write(source_path, yield(marker))
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
