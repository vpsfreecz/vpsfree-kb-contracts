#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class RuntimeContractCheckerTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CHECKER = File.join(ROOT, 'tools/check-runtime-contract.rb')
  CONTRACT = File.join(ROOT, 'contract/runtime.yml')

  def test_current_contract_is_valid
    _output, error, status = run_checker(CONTRACT)

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
      contract.fetch('samples').fetch('check-platform')['sha256'] = '0' * 64
    end

    refute(status.success?)
    assert_match(/check-platform: sample SHA-256 differs/, error)
  end

  def test_section_drift_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.fetch('pages').first.fetch('sections').first['fingerprint'] = '0' * 64
    end

    refute(status.success?)
    assert_match(/section fingerprint differs/, error)
  end

  def test_unknown_test_binding_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.fetch('pages').first.fetch('sections').first['tests'] = ['kb/kvm#missing']
    end

    refute(status.success?)
    assert_match(/unknown tests kb\/kvm#missing/, error)
  end

  def test_bilingual_claim_drift_is_rejected
    _output, error, status = check_mutated_contract do |contract|
      contract.fetch('pages').last.fetch('sections').first.fetch('claims') << 'english-only-claim'
    end

    refute(status.success?)
    assert_match(/bilingual section contracts differ/, error)
  end

  private

  def check_mutated_contract
    contract = YAML.safe_load_file(CONTRACT)
    yield contract

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'runtime.yml')
      File.write(path, YAML.dump(contract))
      run_checker(path)
    end
  end

  def run_checker(contract)
    Open3.capture3(RbConfig.ruby, CHECKER, '--contract', contract, '--root', ROOT)
  end
end
