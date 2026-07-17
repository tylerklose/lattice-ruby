# frozen_string_literal: true

require_relative "test_helper"

class IpogTest < Minitest::Test
  cover "Lattice::IPOG*"
  cover "Lattice::ConstraintEngine*"

  include FixtureHelpers

  def verify_coverage(model, rows, strength)
    engine = Lattice::ConstraintEngine.new(model)
    (0...model.parameters.length).to_a.combination(strength) do |combo|
      domains = combo.map { |index| (0...model.parameters[index].values.length).to_a }
      domains[0].product(*domains[1..]) do |value_tuple|
        partial = combo.each_with_index.to_h { |parameter_index, offset| [parameter_index, value_tuple[offset]] }
        next unless engine.can_complete?(partial)

        covered = rows.any? do |row|
          combo.each_with_index.all? { |parameter_index, offset| row[parameter_index] == value_tuple[offset] }
        end
        flunk "Uncovered tuple for combo #{combo.inspect}: #{value_tuple.inspect}" unless covered
      end
    end
  end

  def test_pairwise_generation_covers_simple_model
    model = load_fixture("simple.json")
    result = Lattice::IPOG.generate_covering_array(model, seed: 42, pool_size: 8)
    verify_coverage(model, result.rows, 2)
  end

  def test_strength_three_generation_covers_simple_model
    model = load_fixture("simple.json").with(strength: 3)
    result = Lattice::IPOG.generate_covering_array(model, seed: 42, pool_size: 8)
    verify_coverage(model, result.rows, 3)
  end

  def test_generation_can_stop_after_coverage_target
    model = load_fixture("simple.json")
    result = Lattice::IPOG.generate_covering_array(model, seed: 42, pool_size: 8, stop_after_coverage: 50)

    assert_equal 2, result.rows.length
    assert_equal 50.0, result.coverage_curve.last.cumulative_pct
  end

  def test_generation_treats_coverage_100_as_full_run
    model = load_fixture("simple.json")
    full_result = Lattice::IPOG.generate_covering_array(model, seed: 42, pool_size: 8)
    stopped_result = Lattice::IPOG.generate_covering_array(model, seed: 42, pool_size: 8, stop_after_coverage: 100)

    assert_equal full_result.rows, stopped_result.rows
    assert_equal 100.0, stopped_result.coverage_curve.last.cumulative_pct
  end

  def test_generation_can_stop_after_max_rows
    model = load_fixture("simple.json")
    result = Lattice::IPOG.generate_covering_array(model, seed: 42, pool_size: 8, max_rows: 2)

    assert_equal 2, result.rows.length
    assert_equal 50.0, result.coverage_curve.last.cumulative_pct
  end

  def test_generation_rejects_invalid_prefix_limits
    model = load_fixture("simple.json")

    error = assert_raises(ArgumentError) { Lattice::IPOG.generate_covering_array(model, max_rows: 0) }
    assert_match(/max_rows/, error.message)

    error = assert_raises(ArgumentError) { Lattice::IPOG.generate_covering_array(model, stop_after_coverage: 0) }
    assert_match(/stop_after_coverage/, error.message)
  end

  def test_constrained_generation_covers_valid_pairs_and_forced_interaction
    model = load_fixture("constrained.json")
    result = Lattice::IPOG.generate_covering_array(model, seed: 42, pool_size: 20)
    verify_coverage(model, result.rows, 2)

    payment_index = model.parameter_names.index("payment_method")
    browser_index = model.parameter_names.index("browser")
    os_index = model.parameter_names.index("os")
    assert(
      result.rows.any? do |row|
        row[payment_index] == model.parameters[payment_index].values.index("apple_pay") &&
          row[browser_index] == model.parameters[browser_index].values.index("safari") &&
          row[os_index] == model.parameters[os_index].values.index("macos")
      end
    )
  end
end
