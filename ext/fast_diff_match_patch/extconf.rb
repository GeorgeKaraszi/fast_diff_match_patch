# frozen_string_literal: true

require "mkmf"

extension_name = "fast_diff_match_patch"

dir_config(extension_name)

# Shamefully coping over OJ's extconf example.

parts    = RUBY_DESCRIPTION.split(" ")
type     = parts[0]
type     = type[4..-1] if type.start_with?("tcs-")
platform = RUBY_PLATFORM
version  = RUBY_VERSION.split(".")
puts ">>>>> Creating Makefile for #{type} version #{RUBY_VERSION} on #{platform} <<<<<"

{
  (type.upcase + "_RUBY") => nil,
  "RUBY_TYPE"             => type,
  "RUBY_VERSION"          => RUBY_VERSION,
  "RUBY_VERSION_MAJOR"    => version[0],
  "RUBY_VERSION_MINOR"    => version[1],
  "RUBY_VERSION_MICRO"    => version[2]
}.each_pair do |k, v|
  $CPPFLAGS += if v.nil?
    " -D#{k}"
  else
    " -D#{k}=#{v}"
  end
end

$CPPFLAGS += " -Wall"

create_makefile(File.join(extension_name, extension_name))

`make clean`
