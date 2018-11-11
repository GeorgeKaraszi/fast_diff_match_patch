# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rake/extensiontask"

task build: :compile

Rake::ExtensionTask.new("google_diff_match_patch") do |ext|
  ext.lib_dir = "lib/google_diff_match_patch"
end

task default: [:clobber, :compile, :spec]
