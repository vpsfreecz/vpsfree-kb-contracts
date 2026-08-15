#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class ManagedArticleSourcesTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CHECKER = File.join(ROOT, 'tools/check-managed-article-sources.rb')
  CONTRACT = File.join(ROOT, 'contract/articles.yml')

  def test_current_managed_sources_are_valid
    _output, error, status = run_checker(YAML.safe_load_file(CONTRACT))

    assert(status.success?, error)
  end

  def test_reader_visible_page_setting_is_rejected
    with_source("export DEBIAN_FRONTEND=noninteractive\n") do |relative|
      contract = YAML.safe_load_file(CONTRACT)
      contract.dig('articles', 'kvm', 'pages', 'cs')['source'] = relative

      _output, error, status = run_checker(contract)

      refute(status.success?)
      assert_match(/kvm:cs:.*reader-visible DEBIAN_FRONTEND is not allowed/, error)
    end
  end

  def test_reader_visible_sample_setting_is_rejected
    with_source("DEBIAN_FRONTEND=noninteractive apt-get install example\n") do |relative|
      contract = YAML.safe_load_file(CONTRACT)
      contract.dig('articles', 'kvm', 'samples', 'install-libvirt')['path'] = relative

      _output, error, status = run_checker(contract)

      refute(status.success?)
      assert_match(/kvm:sample:install-libvirt:.*reader-visible DEBIAN_FRONTEND is not allowed/, error)
    end
  end

  def test_runtime_harness_setting_is_allowed
    runtime = File.read(File.join(ROOT, 'tests/suite/kb/kvm.nix'))
    assert_includes(runtime, 'DEBIAN_FRONTEND')

    _output, error, status = run_checker(YAML.safe_load_file(CONTRACT))
    assert(status.success?, error)
  end

  private

  def with_source(contents)
    Dir.mktmpdir('.managed-article-source-', ROOT) do |dir|
      path = File.join(dir, 'source.txt')
      File.write(path, contents)
      yield path.delete_prefix("#{ROOT}/")
    end
  end

  def run_checker(contract)
    Dir.mktmpdir do |dir|
      contract_path = File.join(dir, 'articles.yml')
      File.write(contract_path, YAML.dump(contract))
      Open3.capture3(
        RbConfig.ruby,
        CHECKER,
        '--contract', contract_path,
        '--root', ROOT
      )
    end
  end
end
