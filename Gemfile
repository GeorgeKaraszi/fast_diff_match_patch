# frozen_string_literal: true

source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

group :development, :test do
  gem "benchmark-ips"
  gem "pry", "~> 0.11.3"
  gem "pry-byebug", "~> 3.5", ">= 3.5.1"
  gem "rubocop", "~> 0.52", require: false
end

# Specify your gem's dependencies in fast_diff_match_patch.gemspec
gemspec
