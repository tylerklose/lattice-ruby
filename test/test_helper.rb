# frozen_string_literal: true

require "minitest/autorun"
require "json"

require "lattice"

module FixtureHelpers
  FIXTURES = File.expand_path("fixtures", __dir__)

  def fixture_path(name)
    File.join(FIXTURES, name)
  end

  def load_fixture(name)
    Lattice::Parser.parse_model_data(JSON.parse(File.read(fixture_path(name))))
  end
end
