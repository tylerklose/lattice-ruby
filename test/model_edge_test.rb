# frozen_string_literal: true

require_relative "test_helper"

class ModelEdgeTest < Minitest::Test
  cover "Lattice::Parameter*"
  cover "Lattice::Model*"
  cover "Lattice.normalize_scalar"

  def model
    @model ||= Lattice.parse_model(
      { "model_name" => "edges", "parameters" => { "a" => %w[1 2], "b" => %w[x y z] } }
    )
  end

  def test_normalize_scalar_stringifies_numbers
    assert_equal "1.5", Lattice.normalize_scalar(1.5)
    assert_equal "-3", Lattice.normalize_scalar(-3)
    assert_equal "text", Lattice.normalize_scalar("text")
  end

  def test_exhaustive_count_is_product_of_domain_sizes
    assert_equal 6, model.exhaustive_count
  end

  def test_parameter_names_and_lookup
    assert_equal %w[a b], model.parameter_names
    assert_equal %w[x y z], model.parameter_lookup["b"].values
  end

  def test_with_strength_preserves_everything_else
    changed = model.with(strength: 3)
    assert_equal 3, changed.strength
    assert_equal model.model_name, changed.model_name
    assert_equal model.parameters, changed.parameters
    assert_equal model.constraints, changed.constraints
  end

  def test_parameter_value_set_membership
    parameter = model.parameter_lookup["a"]
    assert parameter.value_set.include?("1")
    refute parameter.value_set.include?("9")
  end

  def test_default_strength_is_two
    bare = Lattice::Model.new(model_name: "m", parameters: model.parameters, constraints: [])
    assert_equal 2, bare.strength
  end

  def test_collections_are_frozen
    assert_predicate model.parameters, :frozen?
    assert_predicate model.constraints, :frozen?
    assert_predicate model.parameter_names, :frozen?
    assert_predicate model.parameter_lookup, :frozen?
    parameter = model.parameter_lookup["a"]
    assert_predicate parameter.values, :frozen?
    assert_predicate parameter.value_set, :frozen?
    assert_predicate parameter.normalized_weights, :frozen?
  end

  def test_zero_total_weights_fall_back_to_uniform
    parameter = Lattice::Parameter.new(name: "p", values: %w[a b], weights: [0.0, 0.0])
    assert_equal [0.5, 0.5], parameter.normalized_weights
  end
end
