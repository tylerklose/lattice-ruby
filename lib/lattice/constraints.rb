# frozen_string_literal: true

require "set"

require_relative "model"
require_relative "native"

module Lattice
  class ConstraintError < StandardError; end

  # Compiles a model's constraints to the engine's primitives (invalid pairs,
  # requirements, higher-order exclusions, forced interactions), checks the
  # compiled closure for contradictions, and asks the Rust engine whether the
  # model and its forced interactions are satisfiable. Python's
  # lattice.constraints does the same, so both report the same errors.
  # Assignments are `[parameter_index, value_index]` pairs.
  class ConstraintEngine
    EMPTY_SET = Set.new.freeze

    attr_reader :model, :forced_interactions, :native

    def initialize(model)
      @model = model
      @parameter_index = model.parameters.each_with_index.to_h { |parameter, index| [parameter.name, index] }
      @value_index = {}
      model.parameters.each_with_index do |parameter, parameter_idx|
        parameter.values.each_with_index do |value, value_idx|
          @value_index[[parameter_idx, value]] = value_idx
        end
      end
      @invalid_pairs = {}
      @requires = {}
      @higher_order = []
      @forced_interactions = []
      compile_constraints
      compute_implied_pairs
      validate_compiled_constraints
      @native = native_model(model.strength)
      @satisfiable = check_feasibility
    end

    # Whether any row satisfies every constraint.
    def satisfiable?
      @satisfiable
    end

    # Whether some valid row contains every assignment in `partial`
    # (a `{parameter_index => value_index}` hash).
    def can_complete?(partial)
      native.can_complete?(partial.sort)
    end

    def native_model(strength)
      compiled = engine_constraints
      Engine::Model.new(
        model.parameters.map { |parameter| parameter.values.length },
        model.parameters.map(&:normalized_weights),
        strength,
        compiled.fetch(:invalid_pairs),
        compiled.fetch(:requires),
        compiled.fetch(:higher_order),
        compiled.fetch(:forced)
      )
    end

    def conflicts?(left, right)
      invalid_pairs_for(to_ref(left)).include?(to_ref(right))
    end

    # The compiled constraints as the generation engine takes them: invalid
    # pairs and requirements as sorted [[p, v], [q, w]] lists, higher-order
    # exclusions and forced interactions in compile order. Python's
    # lattice.ipog builds the same lists, so the engine gets identical input.
    def engine_constraints
      {
        invalid_pairs: ref_pairs(@invalid_pairs),
        requires: ref_pairs(@requires),
        higher_order: @higher_order,
        forced: @forced_interactions
      }
    end

    def implied_requirements(assignment)
      requires_for(to_ref(assignment)).map { |ref| from_ref(ref) }.sort
    end

    private

    def compile_constraints
      model.constraints.each do |constraint|
        case constraint
        when InvalidPairConstraint
          add_invalid_pair(to_ref(constraint.if_assignment), to_ref(constraint.then_not))
        when BidirectionalConstraint
          left_ref, right_ref = constraint.pair.map { |assignment| to_ref(assignment) }
          add_requirement(left_ref, right_ref)
          add_requirement(right_ref, left_ref)
          exclude_other_values(left_ref, right_ref)
          exclude_other_values(right_ref, left_ref)
        when ForwardDependencyConstraint
          source_ref = to_ref(constraint.source)
          target_ref = to_ref(constraint.target)
          add_requirement(source_ref, target_ref)
          exclude_other_values(source_ref, target_ref)
        when ConditionalConstraint
          compile_conditional(constraint)
        when ForcedConstraint
          @forced_interactions << constraint.assignments.map { |assignment| to_ref(assignment) }
        when HigherOrderConstraint
          antecedents = constraint.if_all.map { |assignment| to_ref(assignment) }
          @higher_order << [antecedents, to_ref(constraint.then_not)]
        end
      end
    end

    def compile_conditional(constraint)
      parent_index = @parameter_index.fetch(constraint.parent)
      child_index = @parameter_index.fetch(constraint.parameter)
      parent = model.parameters[parent_index]
      child = model.parameters[child_index]
      applicable_values = Set.new(constraint.applies_when)
      na_ref = [child_index, @value_index.fetch([child_index, NA_VALUE])]

      parent.values.each_with_index do |parent_value, parent_value_index|
        parent_ref = [parent_index, parent_value_index]
        if applicable_values.include?(parent_value)
          add_invalid_pair(parent_ref, na_ref)
          next
        end

        child.values.each_with_index do |child_value, child_value_index|
          next if child_value == NA_VALUE

          add_invalid_pair(parent_ref, [child_index, child_value_index])
        end
      end
    end

    def compute_implied_pairs
      changed = true
      all_assignments = all_assignment_refs
      while changed
        changed = false

        all_assignments.each do |assignment|
          implied = requires_for(assignment).dup
          implied.to_a.each do |required|
            implied.merge(requires_for(required))
          end
          unless (implied - requires_for(assignment)).empty?
            (@requires[assignment] ||= Set.new).merge(implied)
            changed = true
          end
        end

        all_assignments.each do |assignment|
          additions = Set.new
          invalid_pairs_for(assignment).to_a.each do |conflicting|
            additions.merge(requires_for(conflicting))
          end
          requires_for(assignment).to_a.each do |required|
            additions.merge(invalid_pairs_for(required))
          end
          additions.delete(assignment)
          additions.each do |addition|
            unless invalid_pairs_for(assignment).include?(addition)
              add_invalid_pair(assignment, addition)
              changed = true
            end
          end
        end
      end
    end

    def validate_compiled_constraints
      all_assignment_refs.each do |assignment|
        if invalid_pairs_for(assignment).include?(assignment)
          readable = from_ref(assignment)
          raise ConstraintError, "Constraint closure makes `#{readable.parameter}=#{readable.value}` impossible."
        end

        requires_for(assignment).each do |required|
          if assignment[0] == required[0] && assignment[1] != required[1]
            left = from_ref(assignment)
            right = from_ref(required)
            raise ConstraintError,
                  "Constraint closure requires incompatible values `#{left.parameter}=#{left.value}` and `#{right.parameter}=#{right.value}`."
          end
          if invalid_pairs_for(assignment).include?(required)
            left = from_ref(assignment)
            right = from_ref(required)
            raise ConstraintError,
                  "Constraint closure makes `#{left.parameter}=#{left.value}` conflict with its own requirement `#{right.parameter}=#{right.value}`."
          end
        end
      end

    end

    # Raises for the first impossible forced interaction; otherwise returns
    # whether the model has any valid row.
    def check_feasibility
      native.feasibility
      true
    rescue Engine::ForcedInfeasible => e
      assignments = @forced_interactions.fetch(Integer(e.message)).map do |parameter_index, value_index|
        parameter = model.parameters[parameter_index]
        "#{parameter.name}=#{parameter.values[value_index]}"
      end.join(", ")
      raise ConstraintError, "Forced interaction is not feasible: #{assignments}."
    rescue Engine::NoValidAssignments
      false
    end

    def exclude_other_values(source, required)
      target_parameter = model.parameters[required[0]]
      (0...target_parameter.values.length).each do |value_index|
        next if value_index == required[1]

        add_invalid_pair(source, [required[0], value_index])
      end
    end

    def add_invalid_pair(left, right)
      (@invalid_pairs[left] ||= Set.new).add(right)
      (@invalid_pairs[right] ||= Set.new).add(left)
    end

    def add_requirement(source, target)
      (@requires[source] ||= Set.new).add(target)
    end

    def invalid_pairs_for(ref)
      @invalid_pairs[ref] || EMPTY_SET
    end

    def ref_pairs(table)
      table.flat_map { |source, targets| targets.map { |target| [source, target] } }.sort
    end

    def requires_for(ref)
      @requires[ref] || EMPTY_SET
    end

    def all_assignment_refs
      refs = []
      model.parameters.each_with_index do |parameter, parameter_index|
        (0...parameter.values.length).each do |value_index|
          refs << [parameter_index, value_index]
        end
      end
      refs
    end

    def to_ref(assignment)
      parameter_index = @parameter_index.fetch(assignment.parameter)
      [parameter_index, @value_index.fetch([parameter_index, assignment.value])]
    end

    def from_ref(ref)
      parameter = model.parameters[ref[0]]
      Assignment.new(parameter: parameter.name, value: parameter.values[ref[1]])
    end
  end
end
