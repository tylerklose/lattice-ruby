# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class GemRequireTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  # Bundler.require loads `gem "lattice-cli"` as "lattice/cli"; the library
  # API must be available from that entry point alone.
  def test_requiring_lattice_cli_loads_library_api
    out, status = Open3.capture2e(
      RbConfig.ruby, "-I", LIB, "-e",
      'require "lattice/cli"; print Lattice.respond_to?(:generate)'
    )

    assert status.success?, out
    assert_equal "true", out
  end
end
