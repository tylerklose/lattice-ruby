# frozen_string_literal: true

require_relative "test_helper"

class FormattersEdgeTest < Minitest::Test
  cover "Lattice::Formatters*"

  include FixtureHelpers

  def empty_result
    Lattice::GenerationResult.new(rows: [], coverage_curve: [], total_valid_tuples: 0)
  end

  def test_render_output_rejects_unknown_format
    model = load_fixture("simple.json")
    error = assert_raises(ArgumentError) do
      Lattice::Formatters.render_output(model, empty_result, output_format: "xml", seed: 42)
    end
    assert_equal "Unknown format `xml`.", error.message
  end

  def test_reduction_label_variants
    assert_equal "2x", Lattice::Formatters.reduction_label(6, 3)
    assert_equal "1.5x", Lattice::Formatters.reduction_label(6, 4)
    assert_equal "2.5x", Lattice::Formatters.reduction_label(5, 2)
    assert_equal "inf", Lattice::Formatters.reduction_label(6, 0)
    assert_equal "1x", Lattice::Formatters.reduction_label(7, 7)
  end

  def test_thousands_separators
    assert_equal "999", Lattice::Formatters.thousands(999)
    assert_equal "1,000", Lattice::Formatters.thousands(1000)
    assert_equal "1,234,567", Lattice::Formatters.thousands(1_234_567)
  end

  def test_milestone_lines_report_first_scenario_reaching_each_threshold
    curve = [
      Lattice::CoveragePoint.new(scenario: 1, cumulative_pct: 40.0),
      Lattice::CoveragePoint.new(scenario: 2, cumulative_pct: 75.0),
      Lattice::CoveragePoint.new(scenario: 3, cumulative_pct: 100.0)
    ]
    result = Lattice::GenerationResult.new(rows: [[0]], coverage_curve: curve, total_valid_tuples: 5)

    assert_equal [
      "  50% coverage at scenario #2",
      "  75% coverage at scenario #2",
      "  90% coverage at scenario #3",
      "  100% coverage at scenario #3"
    ], Lattice::Formatters.milestone_lines(result)
  end

  def test_milestone_lines_empty_curve
    assert_empty Lattice::Formatters.milestone_lines(empty_result)
  end

  def test_format_json_with_empty_result_reports_zero_coverage_and_inf_reduction
    model = Lattice.parse_model({ "model_name" => "empty", "parameters" => { "a" => %w[1 2], "b" => %w[x y] } })
    payload = JSON.parse(Lattice::Formatters.format_json(model, empty_result, seed: 9))

    assert_equal "0.0%", payload["meta"]["coverage"]
    assert_equal "inf", payload["meta"]["reduction"]
    assert_equal 0, payload["meta"]["test_count"]
    assert_equal 9, payload["meta"]["seed"]
    assert_empty payload["coverage_curve"]
    assert_empty payload["scenarios"]
  end

  def test_format_summary_headline_counts
    model = load_fixture("simple.json")
    result = Lattice::IPOG.generate_covering_array(model)
    summary = Lattice::Formatters.format_summary(model, result)

    assert_includes summary.lines.first, "Lattice — #{result.rows.length} scenarios"
    assert_includes summary.lines.first, "(from #{model.exhaustive_count} possible)"
  end
end
