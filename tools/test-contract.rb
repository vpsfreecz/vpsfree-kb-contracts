#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class ContractCheckerTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CHECKER = File.join(ROOT, 'tools/check-contract.rb')
  CONTRACT = File.join(ROOT, 'contract/navigation.yml')
  CAPTURES = File.join(ROOT, 'captures.json')
  CATALOG = 'webui/lang/locale/cs_CZ.utf8/LC_MESSAGES/vpsAdmin.po'

  def setup
    @vpsadmin = ENV.fetch('VPSADMIN_KB_VPSADMIN_SOURCE')
  end

  def test_current_contract_is_valid
    _out, error, status = run_checker(CONTRACT, CAPTURES)

    assert(status.success?, error)
  end

  def test_revision_drift_is_rejected
    _out, error, status = check_mutated_contract do |contract|
      contract['vpsadmin_revision'] = '0' * 40
    end
    refute(status.success?)
    assert_match(/revisions differ/, error)
  end

  def test_translation_drift_reports_control_pages_and_captures
    _out, error, status = check_mutated_contract do |contract|
      control = contract.fetch('controls').find { |item| item.fetch('id') == 'vps.features' }
      control.fetch('label')['cs'] = 'Nesprávný překlad'
    end
    refute(status.success?)
    assert_match(/vps\.features: Czech catalog/, error)
    assert_match(/cs=.*navody:vps:sprava/, error)
    assert_match(/en=.*manuals:vps:management/, error)
    assert_match(%r{vps-details/feature-settings, vps-management/feature-settings}, error)
  end

  def test_production_route_label_and_landmark_drift_are_rejected
    mutations = [
      [
        "'?page=networking&action=ip_addresses', 'networking.routable-addresses'",
        "'?page=networking&action=ip_addresses_v2', 'networking.routable-addresses'"
      ],
      ['$xtpl->sbar_add(_("Routable addresses")', '$xtpl->sbar_add(_("Routed addresses")'],
      ["'networking.routable-addresses'", "'networking.routable-addresses.changed'"]
    ]

    mutations.each do |from, to|
      with_vpsadmin_copy do |vpsadmin|
        path = File.join(vpsadmin, 'webui/pages/page_networking.php')
        replace_in_file(path, from, to)
        _out, error, status = run_checker(CONTRACT, CAPTURES, vpsadmin: vpsadmin)

        refute(status.success?, "#{from} -> #{to} was accepted")
        assert_match(/networking\.routable-addresses: coupled label\/route\/landmark declaration changed/, error)
        assert_match(
          %r{cs=navody:vps:ip_adresy, navody:vps:kvm; en=manuals:vps:ip_addresses, manuals:vps:kvm},
          error
        )
        assert_match(
          %r{networking/interface-addresses, networking/ip-address-list, networking/routed-addresses},
          error
        )
      end
    end
  end

  def test_all_source_drifts_are_reported_together
    with_vpsadmin_copy do |vpsadmin|
      replace_in_file(
        File.join(vpsadmin, 'webui/pages/page_networking.php'),
        "'?page=networking&action=ip_addresses', 'networking.routable-addresses'",
        "'?page=networking&action=ip_addresses_v2', 'networking.routable-addresses'"
      )
      replace_in_file(
        File.join(vpsadmin, 'webui/pages/page_adminvps.php'),
        "_('Features')",
        "_('Capabilities')"
      )
      _out, error, status = run_checker(CONTRACT, CAPTURES, vpsadmin: vpsadmin)

      refute(status.success?)
      assert_match(/Documentation contract drift detected \(2\)/, error)
      assert_match(/networking\.routable-addresses:/, error)
      assert_match(/vps\.features:/, error)
    end
  end

  def test_semantic_selector_drift_is_rejected
    with_capture_source_copy do |capture_source|
      path = File.join(capture_source, 'scenarios/vps-management.cjs')
      replace_in_file(path, 'await session.documentationSection(', 'await session.section(')
      _out, error, status = run_checker(
        CONTRACT,
        CAPTURES,
        capture_source: capture_source
      )

      refute(status.success?)
      assert_match(%r{semantic selector changed for vps-management/feature-settings}, error)
    end
  end

  def test_invalid_language_namespace_is_rejected
    _out, error, status = check_mutated_contract do |contract|
      contract.fetch('paths').first.fetch('pages')['en'] = ['navody:wrong-language']
    end
    refute(status.success?)
    assert_match(/en pages use invalid namespaces: navody:wrong-language/, error)
  end

  def test_unknown_capture_binding_is_rejected
    _out, error, status = check_mutated_contract do |contract|
      contract.fetch('controls').first['captures'] = ['missing/capture']
    end
    refute(status.success?)
    assert_match(%r{unknown capture IDs missing/capture}, error)
  end

  private

  def check_mutated_contract
    contract = YAML.safe_load_file(CONTRACT)
    yield contract

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'contract.yml')
      File.write(path, YAML.dump(contract))
      run_checker(path, CAPTURES)
    end
  end

  def with_vpsadmin_copy
    contract = YAML.safe_load_file(CONTRACT)
    files = contract.fetch('controls').flat_map do |control|
      source = control.fetch('source')
      [source.fetch('path')] + source.fetch('related', []).map { |related| related.fetch('path') }
    end
    files << CATALOG

    Dir.mktmpdir do |dir|
      files.uniq.each do |relative|
        destination = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(@vpsadmin, relative), destination)
        FileUtils.chmod(0o644, destination)
      end
      yield dir
    end
  end

  def with_capture_source_copy
    contract = YAML.safe_load_file(CONTRACT)
    files = contract.fetch('semantic_selectors').map { |selector| selector.dig('source', 'path') }

    Dir.mktmpdir do |dir|
      files.uniq.each do |relative|
        destination = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(ROOT, relative), destination)
      end
      yield dir
    end
  end

  def replace_in_file(path, from, to)
    contents = File.read(path)
    raise "#{from.inspect} not found in #{path}" unless contents.include?(from)

    File.write(path, contents.sub(from, to))
  end

  def run_checker(contract, captures, vpsadmin: @vpsadmin, capture_source: ROOT)
    Open3.capture3(
      RbConfig.ruby,
      CHECKER,
      '--contract', contract,
      '--captures', captures,
      '--capture-source', capture_source,
      '--vpsadmin-source', vpsadmin
    )
  end
end
