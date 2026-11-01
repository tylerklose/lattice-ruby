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

    error = assert_raises(ArgumentError) { Lattice::IPOG.generate_covering_array(model, stop_after_coverage: 100.1) }
    assert_equal "`stop_after_coverage` must be in the range (0, 100].", error.message

    error = assert_raises(ArgumentError) { Lattice::IPOG.generate_covering_array(model, pool_size: 0) }
    assert_equal "`pool_size` must be at least 1.", error.message
  end

  def test_generation_rejects_model_with_no_valid_assignments
    model = Lattice::Parser.parse_model_data(
      JSON.parse(File.read(File.join(FixtureHelpers::FIXTURES, "invalid", "no_valid_assignments.json")))
    )
    error = assert_raises(ArgumentError) { Lattice::IPOG.generate_covering_array(model) }
    assert_equal "Model has no valid full assignments.", error.message
  end

  def test_total_valid_tuples_matches_a_brute_force_count
    model = load_fixture("constrained.json")
    engine = Lattice::ConstraintEngine.new(model)
    count = 0
    (0...model.parameters.length).to_a.combination(2) do |combo|
      domains = combo.map { |index| (0...model.parameters[index].values.length).to_a }
      domains[0].product(*domains[1..]) do |values|
        count += 1 if engine.can_complete?(combo.zip(values).to_h)
      end
    end

    assert_equal count, Lattice::IPOG.generate_covering_array(model).total_valid_tuples
  end

  def test_coverage_curve_rises_to_100_with_one_point_per_row
    model = load_fixture("constrained.json")
    result = Lattice::IPOG.generate_covering_array(model)

    assert_equal (1..result.rows.length).to_a, result.coverage_curve.map(&:scenario)
    assert_equal 100.0, result.coverage_curve.last.cumulative_pct
    assert_equal result.coverage_curve.map(&:cumulative_pct).sort, result.coverage_curve.map(&:cumulative_pct)
  end

  def test_progress_reports_enumeration_then_each_scenario
    model = load_fixture("simple.json")
    events = []
    result = Lattice::IPOG.generate_covering_array(model, progress: ->(event) { events << event })

    assert_equal ["enumerated"] + (["scenario"] * result.rows.length), events.map(&:event)
    assert_equal 0, events.first.covered
    assert_equal events.first.total, events.last.covered
    assert_equal 0, events.last.uncovered
  end

  def test_progress_reports_stopped_when_cut_short
    model = load_fixture("simple.json")
    events = []
    Lattice::IPOG.generate_covering_array(model, max_rows: 1, progress: ->(event) { events << event })

    assert_equal %w[enumerated scenario stopped], events.map(&:event)
  end

  def test_seeds_wrap_like_unsigned_64_bit_integers
    model = load_fixture("skillit.json")

    assert_equal Lattice::IPOG.generate_covering_array(model, seed: 2**64 - 1).rows,
                 Lattice::IPOG.generate_covering_array(model, seed: -1).rows
  end

  def test_coverage_percentages_round_half_to_even_like_python
    assert_in_delta 0.2, Lattice::IPOG.send(:coverage_pct, 1, 400), 0.0
    assert_in_delta 0.4, Lattice::IPOG.send(:coverage_pct, 3, 800), 0.0
    assert_in_delta 33.3, Lattice::IPOG.send(:coverage_pct, 1, 3), 0.0
  end

  def test_engine_constraints_are_sorted_primitives
    compiled = Lattice::ConstraintEngine.new(load_fixture("constrained.json")).engine_constraints

    assert_equal compiled[:invalid_pairs].sort, compiled[:invalid_pairs]
    assert_equal compiled[:requires].sort, compiled[:requires]
    refute_empty compiled[:invalid_pairs]
    refute_empty compiled[:requires]
    assert_equal 1, compiled[:higher_order].length
    assert_equal 1, compiled[:forced].length
    compiled[:invalid_pairs].each { |left, right| assert_includes compiled[:invalid_pairs], [right, left] }
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
