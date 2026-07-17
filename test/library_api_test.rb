# frozen_string_literal: true

require_relative "test_helper"

class LibraryApiTest < Minitest::Test
  cover "Lattice.generate"
  cover "Lattice.parse_model"
  cover "Lattice.scenarios"
  cover "Lattice.validate!"
  cover "Lattice::Run*"
  cover "Lattice::Parser*"

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

  GOLDEN_DIR = File.join(FixtureHelpers::FIXTURES, "golden")

  def golden(name) = File.read(File.join(GOLDEN_DIR, name))

  def test_run_to_csv_matches_golden_snapshot
    run = Lattice.generate(file: fixture_path("simple.json"), strength: 3, pool_size: 1)
    assert_equal golden("14_simple_s3_default_pool_minimal_none_csv.golden"), run.to_csv + "\n"
  end

  def test_run_to_summary_matches_golden_snapshot
    run = Lattice.generate(file: fixture_path("simple.json"), strength: 3, seed: 7)
    assert_equal golden("04_simple_s3_alt_pool_default_none_summary.golden"), run.to_summary + "\n"
  end

  def test_run_to_table_matches_golden_snapshot
    run = Lattice.generate(file: fixture_path("simple.json"), strength: 3, pool_size: 1, stop_after_coverage: 75)
    assert_equal golden("13_simple_s3_default_pool_minimal_stop_pct_table.golden"), run.to_table + "\n"
  end

  def test_run_to_json_output_matches_golden_snapshot
    run = Lattice.generate(file: fixture_path("simple.json"), strength: 1, seed: 7, pool_size: 1, max_rows: 3)
    assert_equal golden("05_simple_s1_alt_pool_minimal_max_rows_json.golden"), run.to_json_output + "\n"
  end

  def test_run_exposes_seed_model_and_coverage_curve
    run = Lattice.generate(file: fixture_path("simple.json"), seed: 7)
    assert_equal 7, run.seed
    assert_equal "simple", run.model.model_name
    assert_equal 100.0, run.coverage_curve.last.cumulative_pct
    assert_equal (1..run.scenarios.length).to_a, run.coverage_curve.map(&:scenario)
  end

  def test_each_scenario_yields_every_scenario
    run = Lattice.generate(file: fixture_path("simple.json"))
    yielded = []
    run.each_scenario { |scenario| yielded << scenario }
    assert_equal run.scenarios, yielded
  end

  def test_generate_default_pool_size_matches_golden_snapshot
    run = Lattice.generate(file: fixture_path("skillit.json"), seed: 7, stop_after_coverage: 75.0)
    assert_equal golden("10_skillit_s2_alt_pool_default_stop_pct_json.golden"), run.to_json_output + "\n"
  end

  def test_validate_bang_applies_strength_override
    model = Lattice.validate!(file: fixture_path("simple.json"), strength: 3)
    assert_equal 3, model.strength
  end

  def test_validate_bang_returns_model_for_valid_schema
    model = Lattice.validate!(file: fixture_path("constrained.json"))
    assert_equal "payments", model.model_name
  end

  def test_parse_model_accepts_model_with_strength_override
    base = Lattice.parse_model(file: fixture_path("simple.json"))
    overridden = Lattice.parse_model(base, strength: 3)
    assert_equal 3, overridden.strength
    assert_same base, Lattice.parse_model(base)
  end

  def test_parse_model_rejects_unsupported_source
    assert_raises(ArgumentError) { Lattice.parse_model(42) }
  end
end
