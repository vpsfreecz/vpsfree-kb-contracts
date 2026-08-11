#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

contract = YAML.safe_load_file(File.expand_path('../contract/articles.yml', __dir__))
abort 'article contract schema must be 1' unless contract.fetch('schema') == 1

articles = contract.fetch('articles').keys
abort 'articles must not be empty' if articles.empty?

puts JSON.generate('include' => articles.map { |article| { 'article' => article } })
