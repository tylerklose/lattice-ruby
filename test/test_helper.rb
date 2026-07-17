# frozen_string_literal: true

require "minitest/autorun"
require "json"

require "lattice"

# Load mutant's `cover` DSL when available so test classes can declare which
# subjects they kill mutations for; no-op under plain `rake test` without it.
begin
  require "mutant/minitest/coverage"
rescue LoadError
  Minitest::Test.define_singleton_method(:cover) { |_expression| }
end

module FixtureHelpers
  FIXTURES = File.expand_path("fixtures", __dir__)

  def fixture_path(name)
    File.join(FIXTURES, name)
  end

  def load_fixture(name)
    Lattice::Parser.parse_model_data(JSON.parse(File.read(fixture_path(name))))
  end
end
