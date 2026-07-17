# frozen_string_literal: true

require_relative "test_helper"

class ConstraintsTest < Minitest::Test
  cover "Lattice::ConstraintEngine*"

  include FixtureHelpers

  def engine
    @engine ||= Lattice::ConstraintEngine.new(load_fixture("constrained.json"))
  end

  def test_implied_pairs_capture_transitive_conflicts
    assert engine.conflicts?(
      Lattice::Assignment.new(parameter: "loyalty", value: "gold"),
      Lattice::Assignment.new(parameter: "card_type", value: "N/A")
    )
  end

  def test_forward_dependency_survives_closure
    requirements = engine.implied_requirements(Lattice::Assignment.new(parameter: "loyalty", value: "gold"))
    assert_includes requirements, Lattice::Assignment.new(parameter: "payment_method", value: "credit_card")
  end

  def test_model_is_feasible
    assert engine.can_complete?({})
  end
end
