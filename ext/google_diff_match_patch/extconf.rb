# frozen_string_literal: true

require "mkmf"

extension_name = "google_diff_match_patch"
dir_config(extension_name)
create_makefile(extension_name)
