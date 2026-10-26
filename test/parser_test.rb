# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "yaml"

class ParserTest < Minitest::Test
  cover "Lattice::Parser*"

  def test_yaml_mapping_parameters_and_conditional_parameter_are_supported
    raw = YAML.safe_load(<<~YAML)
      model_name: checkout
      parameters:
        payment_method: [credit_card, paypal]
        region: [US, UK]
      constraints:
        - type: conditional
          parameter: card_type
          values: [visa, mastercard]
          parent: payment_method
          applies_when: [credit_card]
      strength: 2
    YAML

    model = Lattice::Parser.parse_model_data(raw)

    assert_includes model.parameter_lookup, "card_type"
    assert_equal ["visa", "mastercard", "N/A"], model.parameter_lookup["card_type"].values
  end

  def test_values_normalize_non_string_scalars
    model = Lattice::Parser.parse_model_data(
      { "parameters" => { "a" => [1, true, nil], "b" => %w[p q] } }
    )
    assert_equal %w[1 true null], model.parameter_lookup["a"].values
  end

  def test_model_name_is_normalized_to_a_string
    model = Lattice::Parser.parse_model_data(
      { "model_name" => 42, "parameters" => { "a" => %w[x y], "b" => %w[p q] } }
    )
    assert_equal "42", model.model_name
  end

  def test_float_strength_truncates_like_python_int
    model = Lattice::Parser.parse_model_data(
      { "parameters" => { "a" => %w[x y], "b" => %w[p q] }, "strength" => 2.9 }
    )
    assert_equal 2, model.strength
  end

  def test_stdin_is_read_for_nil_and_dash_paths
    schema = JSON.generate({ "parameters" => { "a" => %w[x y], "b" => %w[p q] } })
    [nil, "-"].each do |path|
      with_stdin(schema) do
        assert_equal %w[a b], Lattice::Parser.load_model(path).parameter_names
      end
    end
  end

  def test_blank_stdin_raises_model_io_error
    with_stdin("   \n") do
      error = assert_raises(Lattice::ModelIOError) { Lattice::Parser.load_model(nil) }
      assert_equal "No model content found on stdin.", error.message
    end
  end

  def test_yaml_timestamps_keep_their_text
    model = Lattice::Parser.parse_model_data(
      Lattice::SchemaText.load_yaml(<<~YAML)
        parameters:
          released: [2024-01-15, 2024-06-01]
          when: [2024-01-15 10:00:00, 2024-06-01T12:30:00Z]
      YAML
    )
    assert_equal %w[2024-01-15 2024-06-01], model.parameter_lookup["released"].values
    assert_equal ["2024-01-15 10:00:00", "2024-06-01T12:30:00Z"], model.parameter_lookup["when"].values
  end

  def with_stdin(text)
    original = $stdin
    $stdin = StringIO.new(text)
    yield
  ensure
    $stdin = original
  end

  def test_invalid_duplicate_values_raise_validation_error
    assert_raises(Lattice::ValidationError) do
      Lattice::Parser.parse_model_data({ "parameters" => { "browser" => %w[chrome chrome] } })
    end
  end

  def test_conditional_conflict_suggests_exclusion_constraints
    raised = assert_raises(Lattice::ValidationError) do
      Lattice::Parser.parse_model_data(
        {
          "parameters" => {
            "mode" => %w[basic advanced],
            "aggregation_level" => %w[none low high]
          },
          "constraints" => [
            {
              "type" => "conditional",
              "parameter" => "aggregation_level",
              "values" => %w[low high],
              "parent" => "mode",
              "applies_when" => %w[advanced]
            }
          ]
        }
      )
    end

    message = raised.errors.join("\n")
    assert_includes message, "Use `conditional` only to define a child parameter"
    assert_includes message, "invalid_pair"
    assert_includes message, "higher_order"
  end

  def test_yaml_fixture_parses_like_json_fixture
    yaml_model = Lattice::Parser.load_model(File.expand_path("fixtures/simple.yaml", __dir__))
    json_model = Lattice::Parser.load_model(File.expand_path("fixtures/simple.json", __dir__))

    assert_equal json_model.parameter_names, yaml_model.parameter_names
    assert_equal json_model.strength, yaml_model.strength
  end
end
