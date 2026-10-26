# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class GemRequireTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  # Bundler.require loads `gem "latticerb"` as "latticerb"; the CLI entry
  # point must also expose the library API.
  %w[latticerb lattice/cli].each do |path|
    define_method("test_requiring_#{path.tr('/', '_')}_loads_library_api") do
      out, status = Open3.capture2e(
        RbConfig.ruby, "-I", LIB, "-e",
        "require #{path.inspect}; print Lattice.respond_to?(:generate)"
      )

      assert status.success?, out
      assert_equal "true", out
    end
  end
end
