# frozen_string_literal: true

require_relative "test_helper"

class ConstraintsEdgeTest < Minitest::Test
  cover "Lattice::ConstraintEngine*"
  cover "Lattice::Assignment*"

  include FixtureHelpers

  # constrained.json parameter order:
  #   0 payment_method [credit_card, paypal, apple_pay]
  #   1 region        [US, UK]
  #   2 currency      [USD, GBP]
  #   3 os            [macos, windows]
  #   4 browser       [chrome, safari]
  #   5 loyalty       [none, gold]
  #   6 card_type     [visa, mastercard, N/A]  (added by the conditional)
  def engine
    @engine ||= Lattice::ConstraintEngine.new(load_fixture("constrained.json"))
  end

  def assignment(parameter, value)
    Lattice::Assignment.new(parameter:, value:)
  end

  def test_conflicts_is_symmetric
    left = assignment("loyalty", "gold")
    right = assignment("card_type", "N/A")
    assert engine.conflicts?(left, right)
    assert engine.conflicts?(right, left)
  end

  def test_bidirectional_excludes_other_values_of_the_pair
    assert engine.conflicts?(assignment("browser", "safari"), assignment("os", "windows"))
    assert engine.conflicts?(assignment("os", "macos"), assignment("browser", "chrome"))
  end

  def test_requirements_propagate_transitively
    chained = Lattice.parse_model(
      {
        "parameters" => { "a" => %w[x y], "b" => %w[p q], "c" => %w[m n] },
        "constraints" => [
          { "type" => "forward_dep", "source" => { "parameter" => "a", "value" => "x" },
            "target" => { "parameter" => "b", "value" => "p" } },
          { "type" => "forward_dep", "source" => { "parameter" => "b", "value" => "p" },
            "target" => { "parameter" => "c", "value" => "m" } }
        ]
      }
    )
    requirements = Lattice::ConstraintEngine.new(chained).implied_requirements(assignment("a", "x"))
    assert_includes requirements, assignment("c", "m")
  end

  def test_conflicts_is_false_for_compatible_assignments
    refute engine.conflicts?(assignment("region", "US"), assignment("currency", "USD"))
  end

  def test_implied_requirements_empty_for_unconstrained_assignment
    assert_empty engine.implied_requirements(assignment("region", "US"))
  end

  def test_implied_requirements_sorted
    requirements = engine.implied_requirements(assignment("loyalty", "gold"))
    assert_equal requirements.sort, requirements
    refute_empty requirements
  end

  def test_forced_interactions_compile_to_assignment_refs_in_order
    assert_equal [[[0, 2], [4, 1], [3, 0]]], engine.forced_interactions
  end

  def test_can_complete_accepts_a_valid_full_row
    # apple_pay, US, USD, macos, safari, none, N/A
    assert engine.can_complete?({ 0 => 2, 1 => 0, 2 => 0, 3 => 0, 4 => 1, 5 => 0, 6 => 2 })
  end

  def test_can_complete_rejects_a_higher_order_violation
    # apple_pay + UK + USD violates the higher_order constraint; all pairs valid.
    refute engine.can_complete?({ 0 => 2, 1 => 1, 2 => 0, 3 => 0, 4 => 1, 5 => 0, 6 => 2 })
  end

  def test_can_complete_rejects_an_invalid_pair
    # apple_pay + windows violates the invalid_pair.
    refute engine.can_complete?({ 0 => 2, 1 => 0, 2 => 0, 3 => 1, 4 => 0, 5 => 0, 6 => 2 })
  end

  def test_can_complete_accepts_a_completable_partial_row
    assert engine.can_complete?({ 0 => 2, 1 => 0, 2 => 0 })
  end

  def test_can_complete_rejects_conflicting_partial
    refute engine.can_complete?({ 0 => 2, 3 => 1 })
  end

  def test_can_complete_follows_implied_requirements
    # loyalty=gold requires payment_method=credit_card.
    assert engine.can_complete?({ 5 => 1, 0 => 0 })
    refute engine.can_complete?({ 5 => 1, 0 => 1 })
  end

  def test_can_complete_answers_are_stable
    partial = { 0 => 2, 3 => 1 }
    assert_equal engine.can_complete?(partial), engine.can_complete?(partial)
  end

  def test_satisfiable_model
    assert_predicate engine, :satisfiable?
  end

  def test_engine_rejects_out_of_range_assignments
    error = assert_raises(ArgumentError) { engine.can_complete?({ 9 => 0 }) }
    assert_match(/out of range/, error.message)
  end

  def test_assignments_compare_by_parameter_then_value
    assert_operator assignment("a", "x"), :<, assignment("b", "a")
    assert_operator assignment("a", "x"), :<, assignment("a", "y")
    assert_equal 0, (assignment("a", "x") <=> assignment("a", "x"))
  end
end
