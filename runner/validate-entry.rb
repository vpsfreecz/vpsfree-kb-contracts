#!/usr/bin/env ruby
# frozen_string_literal: true
require 'rbconfig'

source = File.expand_path('..', __dir__)
default_root = ARGV.shift
metadata_file = ARGV.shift
arguments = ARGV.dup
index = arguments.index('--output-root')
output = File.expand_path(index ? arguments.fetch(index + 1) : default_root)
arguments += ['--output-root', output] unless index
arguments += ['--source-metadata', metadata_file] unless metadata_file == '-'
puts "Source: #{source}\nOutput: #{output}"
exec(RbConfig.ruby, File.join(source, 'cluster/artifact-lock.rb'), output, '--exec',
     RbConfig.ruby, File.join(source, 'runner/validate.rb'), *arguments)
