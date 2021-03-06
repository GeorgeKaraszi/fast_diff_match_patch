# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fast_diff_match_patch/version"

Gem::Specification.new do |spec|
  spec.name          = "fast_diff_match_patch"
  spec.version       = FastDiffMatchPatch::VERSION
  spec.authors       = ["George Karaszi"]
  spec.email         = ["georgekaraszi@gmail.com"]

  spec.summary       = "Implements Google's Diff-Match-Patch in a pure optimised ruby implementation"
  spec.description   = "Implements Google's Diff-Match-Patch in a pure optimised ruby implementation"
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = Dir["README.md", "lib/**/*", "ext/**/*"]
  spec.test_files    = `git ls-files -- spec/*`.split("\n")
  spec.require_paths = ["lib"]
  spec.extensions    = "ext/fast_diff_match_patch/extconf.rb"

  spec.add_development_dependency "bundler", "~> 1.16"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rake-compiler"
  spec.add_development_dependency "rspec", "~> 3.0"
end
