# frozen_string_literal: true

require "set"

require_relative "model"

module Lattice
  class ConstraintError < StandardError; end

  # Compiles model constraints into invalid-pair / requirement closures and
  # answers feasibility questions over partial assignments. Assignments are
  # referenced as `[parameter_index, value_index]` pairs; partial assignments
  # are `{parameter_index => value_index}` hashes.
  class ConstraintEngine
    EMPTY_SET = Set.new.freeze

    attr_reader :model, :forced_interactions

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
      @feasibility_cache = {}
      compile_constraints
      compute_implied_pairs
      validate_compiled_constraints
    end

    def conflicts?(left, right)
      invalid_pairs_for(to_ref(left)).include?(to_ref(right))
    end

    def implied_requirements(assignment)
      requires_for(to_ref(assignment)).map { |ref| from_ref(ref) }.sort
    end

    def can_complete?(partial)
      normalized = normalize_partial(partial.dup)
      return false if normalized.nil?

      signature = normalized.sort
      cached = @feasibility_cache[signature]
      return cached unless cached.nil?

      result = !backtrack_complete(normalized, rng: nil, failures: Set.new).nil?
      @feasibility_cache[signature] = result
      result
    end

    def complete_assignment(partial, rng: nil)
      normalized = normalize_partial(partial.dup)
      return nil if normalized.nil?

      backtrack_complete(normalized, rng:, failures: Set.new)
    end

    def complete_assignment_valid?(row)
      partial = row.each_with_index.to_h { |value_index, parameter_index| [parameter_index, value_index] }
      normalized = normalize_partial(partial)
      return false if normalized.nil? || normalized.length != model.parameters.length

      @higher_order.each do |antecedents, forbidden|
        if antecedents.all? { |parameter_index, value_index| normalized[parameter_index] == value_index }
          return false if normalized[forbidden[0]] == forbidden[1]
        end
      end
      true
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

      @forced_interactions.each do |forced|
        partial = forced.to_h { |parameter_index, value_index| [parameter_index, value_index] }
        next unless complete_assignment(partial, rng: nil).nil?

        assignments = forced.map do |parameter_index, value_index|
          parameter = model.parameters[parameter_index]
          "#{parameter.name}=#{parameter.values[value_index]}"
        end.join(", ")
        raise ConstraintError, "Forced interaction is not feasible: #{assignments}."
      end
    end

    def normalize_partial(partial)
      normalized = partial.dup
      changed = true
      while changed
        changed = false
        return nil unless partial_consistent?(normalized)

        normalized.to_a.each do |parameter_index, value_index|
          requires_for([parameter_index, value_index]).each do |required_parameter, required_value|
            current = normalized[required_parameter]
            if current.nil?
              normalized[required_parameter] = required_value
              changed = true
            elsif current != required_value
              return nil
            end
          end
        end
      end
      return nil unless partial_consistent?(normalized)

      normalized
    end

    def partial_consistent?(partial)
      partial.each do |parameter_index, value_index|
        partial.each do |other_parameter, other_value|
          next if parameter_index == other_parameter

          return false if invalid_pairs_for([parameter_index, value_index]).include?([other_parameter, other_value])
        end
      end

      @higher_order.each do |antecedents, forbidden|
        if antecedents.all? { |parameter_index, value_index| partial[parameter_index] == value_index }
          return false if partial[forbidden[0]] == forbidden[1]
        end
      end
      true
    end

    def backtrack_complete(partial, rng:, failures:)
      signature = partial.sort
      return nil if failures.include?(signature)

      if partial.length == model.parameters.length
        row = (0...model.parameters.length).map { |index| partial.fetch(index) }
        return complete_assignment_valid?(row) ? row : nil
      end

      next_parameter, values = next_parameter_values(partial)
      if next_parameter.nil?
        failures.add(signature)
        return nil
      end

      ordered_values(next_parameter, values, rng).each do |value|
        candidate = partial.dup
        candidate[next_parameter] = value
        normalized = normalize_partial(candidate)
        next if normalized.nil?

        result = backtrack_complete(normalized, rng:, failures:)
        return result unless result.nil?
      end

      failures.add(signature)
      nil
    end

    def next_parameter_values(partial)
      best_parameter = nil
      best_values = []
      best_size = nil

      model.parameters.each_with_index do |parameter, parameter_index|
        next if partial.key?(parameter_index)

        feasible = []
        (0...parameter.values.length).each do |value_index|
          candidate = partial.dup
          candidate[parameter_index] = value_index
          feasible << value_index unless normalize_partial(candidate).nil?
        end

        return [nil, []] if feasible.empty?

        if best_size.nil? || feasible.length < best_size
          best_parameter = parameter_index
          best_values = feasible
          best_size = feasible.length
        end
      end

      [best_parameter, best_values]
    end

    def ordered_values(parameter_index, values, rng)
      parameter = model.parameters[parameter_index]
      if rng.nil?
        return values.sort_by { |value_index| [-parameter.normalized_weights[value_index], value_index] }
      end

      values
        .map { |value_index| [rng.random / [parameter.normalized_weights[value_index], 1e-9].max, value_index] }
        .sort
        .map { |_, value_index| value_index }
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
