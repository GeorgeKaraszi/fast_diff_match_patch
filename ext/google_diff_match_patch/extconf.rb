# frozen_string_literal: true

require "mkmf"
require "rbconfig"

extension_name = "google_diff_match_patch"

dir_config(extension_name)

# Shamefully coping over OJ's extconf example.

parts    = RUBY_DESCRIPTION.split(" ")
type     = parts[0]
type     = type[4..-1] if type.start_with?("tcs-")
platform = RUBY_PLATFORM
version  = RUBY_VERSION.split(".")
puts ">>>>> Creating Makefile for #{type} version #{RUBY_VERSION} on #{platform} <<<<<"

dflags = {
  "RUBY_TYPE" => type,
  (type.upcase + "_RUBY")              => nil,
  "RUBY_VERSION"                       => RUBY_VERSION,
  "RUBY_VERSION_MAJOR"                 => version[0],
  "RUBY_VERSION_MINOR"                 => version[1],
  "RUBY_VERSION_MICRO"                 => version[2],
  "RSTRUCT_LEN_RETURNS_INTEGER_OBJECT" => type == "ruby" && version[0] == "2" && version[1] == "4" && version[2] <= "1" ? 1 : 0
}

dflags.each do |k, v|
  $CPPFLAGS += if v.nil?
    " -D#{k}"
  else
    " -D#{k}=#{v}"
  end
end

$CPPFLAGS += " -Wall"

create_makefile(File.join(extension_name, extension_name))

`make clean`
