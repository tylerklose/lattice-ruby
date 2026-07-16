# frozen_string_literal: true

require_relative "test_helper"

class LibraryApiTest < Minitest::Test
  include FixtureHelpers

  def test_generate_from_file_returns_named_scenarios
    run = Lattice.generate(file: fixture_path("simple.json"))

    refute_empty run.scenarios
    run.scenarios.each do |scenario|
      assert_equal run.model.parameter_names.sort, scenario.keys.sort
      scenario.each do |name, value|
        assert_includes run.model.parameter_lookup[name].values, value
      end
    end
  end

  def test_generate_from_hash_and_yaml_string_agree
    schema = {
      "model_name" => "inline",
      "parameters" => { "a" => %w[1 2], "b" => %w[x y] }
    }
    from_hash = Lattice.generate(schema)
    from_yaml = Lattice.generate(<<~YAML)
      model_name: inline
      parameters:
        a: ["1", "2"]
        b: [x, y]
    YAML

    assert_equal from_hash.scenarios, from_yaml.scenarios
  end

  def test_scenarios_shortcut
    scenarios = Lattice.scenarios(file: fixture_path("simple.json"))
    assert_kind_of Array, scenarios
    assert_kind_of Hash, scenarios.first
  end

  def test_validate_bang_raises_on_invalid_schema
    assert_raises(Lattice::ValidationError) do
      Lattice.validate!({ "parameters" => { "a" => ["1", "1"] } })
    end
  end

  def test_generation_is_deterministic_for_a_seed
    first = Lattice.generate(file: fixture_path("constrained.json"), seed: 7)
    second = Lattice.generate(file: fixture_path("constrained.json"), seed: 7)
    assert_equal first.scenarios, second.scenarios
  end
end
