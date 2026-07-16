# frozen_string_literal: true

require_relative "test_helper"

class ModelTest < Minitest::Test
  def test_normalize_scalar_canonicalizes_yaml_scalars
    assert_equal "true", Lattice.normalize_scalar(true)
    assert_equal "false", Lattice.normalize_scalar(false)
    assert_equal "null", Lattice.normalize_scalar(nil)
    assert_equal "7", Lattice.normalize_scalar(7)
  end

  def test_parameter_normalizes_weights
    parameter = Lattice::Parameter.new(name: "browser", values: %w[chrome safari], weights: [0.7, 0.3])
    assert_equal [0.7, 0.3], parameter.normalized_weights
  end

  def test_parameter_defaults_to_uniform_weights
    parameter = Lattice::Parameter.new(name: "browser", values: %w[chrome safari])
    assert_equal [0.5, 0.5], parameter.normalized_weights
  end
end
