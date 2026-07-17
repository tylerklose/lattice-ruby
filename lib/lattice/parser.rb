# frozen_string_literal: true

require "json"
require "yaml"

require_relative "model"

module Lattice
  class ModelIOError < StandardError; end

  class ValidationError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.join("\n"))
    end
  end

  module Parser
    extend self

    def load_model(path, strength_override: nil)
      text, source_name, extension = read_model_input(path)
      data = deserialize_model(text, source_name, extension)
      parse_model_data(data, strength_override:)
    end

    def parse_model_data(data, strength_override: nil)
      raise ValidationError, ["Model root must be a JSON/YAML object."] unless data.is_a?(Hash)

      errors = []
      parameters = parse_parameters(data["parameters"], errors)
      raw_constraints = data.fetch("constraints", []) || []
      unless raw_constraints.is_a?(Array)
        errors << "`constraints` must be a list."
        raw_constraints = []
      end

      apply_conditional_parameters(parameters, raw_constraints, errors)
      constraints = parse_constraints(raw_constraints, parameters, errors)
      strength = parse_strength(strength_override.nil? ? data["strength"] : strength_override, parameters.length, errors)
      model_name = Lattice.normalize_scalar(data.fetch("model_name", "unnamed_model"))

      raise ValidationError, errors unless errors.empty?

      Model.new(
        model_name:,
        parameters: parameters.values,
        constraints:,
        strength:
      )
    end

    def read_model_input(path)
      if path.nil? || path == "-"
        text = $stdin.read
        raise ModelIOError, "No model content found on stdin." if text.strip.empty?

        return [text, "stdin", nil]
      end

      begin
        text = File.read(path, encoding: "UTF-8")
      rescue SystemCallError, IOError => e
        raise ModelIOError, "Unable to read model file `#{path}`: #{e.message}"
      end
      [text, path, File.extname(path).downcase]
    end

    def deserialize_model(text, source_name, extension)
      loaders =
        case extension
        when ".json" then [:json]
        when ".yaml", ".yml" then [:yaml]
        else [:json, :yaml]
        end

      errors = []
      loaders.each do |loader|
        return loader == :json ? JSON.parse(text) : safe_load_yaml(text)
      rescue StandardError => e
        errors << e.message
      end

      raise ModelIOError, "Unable to parse model from `#{source_name}`: #{errors.join('; ')}"
    end

    def safe_load_yaml(text)
      YAML.safe_load(text, permitted_classes: [Date, Time], aliases: true)
    end

    def parse_parameters(raw_parameters, errors)
      parameters = {}
      if raw_parameters.nil?
        errors << "`parameters` is required."
        return parameters
      end

      case raw_parameters
      when Hash
        raw_parameters.each { |name, spec| add_parameter(parameters, name, spec, errors) }
      when Array
        raw_parameters.each_with_index do |raw_parameter, index|
          unless raw_parameter.is_a?(Hash)
            errors << "`parameters[#{index}]` must be an object."
            next
          end
          name = raw_parameter["name"]
          if name.nil?
            errors << "`parameters[#{index}]` is missing `name`."
            next
          end
          add_parameter(parameters, name, raw_parameter, errors)
        end
      else
        errors << "`parameters` must be a mapping or list."
      end
      parameters
    end

    def add_parameter(parameters, name, spec, errors)
      normalized_name = Lattice.normalize_scalar(name)
      if parameters.key?(normalized_name)
        errors << "Duplicate parameter `#{normalized_name}`."
        return
      end

      if spec.is_a?(Hash)
        values = spec["values"]
        weights = spec["weights"]
      else
        values = spec
        weights = nil
      end

      parsed_values = parse_values(values, "parameter `#{normalized_name}`", errors)
      parsed_weights = parse_weights(weights, parsed_values, normalized_name, errors)
      return if parsed_values.empty?

      parameters[normalized_name] = Parameter.new(
        name: normalized_name,
        values: parsed_values,
        weights: parsed_weights
      )
    end

    def apply_conditional_parameters(parameters, raw_constraints, errors)
      raw_constraints.each_with_index do |raw_constraint, index|
        next unless raw_constraint.is_a?(Hash)
        next unless raw_constraint["type"] == "conditional"

        parameter_name = Lattice.normalize_scalar(raw_constraint["parameter"])
        values = parse_values(raw_constraint["values"], "`constraints[#{index}]` conditional values", errors)
        next if values.empty?

        conditional_values = values
        conditional_values = conditional_values + [NA_VALUE] unless conditional_values.include?(NA_VALUE)

        existing = parameters[parameter_name]
        if existing.nil?
          parameters[parameter_name] = Parameter.new(name: parameter_name, values: conditional_values)
          next
        end

        next if Set.new(existing.values) == Set.new(conditional_values)

        errors << (
          "Conditional parameter `#{parameter_name}` conflicts with an existing parameter definition. " \
          "Use `conditional` only to define a child parameter that applies under parent values. " \
          "For exclusions or requirements between existing parameters, use `invalid_pair`, " \
          "`higher_order`, `forward_dep`, or `bidirectional`; run `lattice agent instructions` " \
          "for the full schema reference."
        )
      end
    end

    def parse_constraints(raw_constraints, parameters, errors)
      parsed = []
      raw_constraints.each_with_index do |raw_constraint, index|
        unless raw_constraint.is_a?(Hash)
          errors << "`constraints[#{index}]` must be an object."
          next
        end

        case raw_constraint["type"]
        when "invalid_pair"
          if_assignment = parse_assignment(raw_constraint["if"], parameters, "`constraints[#{index}].if`", errors)
          then_not = parse_assignment(raw_constraint["then_not"], parameters, "`constraints[#{index}].then_not`", errors)
          parsed << InvalidPairConstraint.new(if_assignment:, then_not:) if if_assignment && then_not
        when "bidirectional"
          pair = raw_constraint["pair"]
          unless pair.is_a?(Array) && pair.length == 2
            errors << "`constraints[#{index}].pair` must contain exactly two assignments."
            next
          end
          left = parse_assignment(pair[0], parameters, "`constraints[#{index}].pair[0]`", errors)
          right = parse_assignment(pair[1], parameters, "`constraints[#{index}].pair[1]`", errors)
          parsed << BidirectionalConstraint.new(pair: [left, right]) if left && right
        when "forward_dep"
          source = parse_assignment(raw_constraint["source"], parameters, "`constraints[#{index}].source`", errors)
          target = parse_assignment(raw_constraint["target"], parameters, "`constraints[#{index}].target`", errors)
          parsed << ForwardDependencyConstraint.new(source:, target:) if source && target
        when "conditional"
          constraint = parse_conditional_constraint(raw_constraint, index, parameters, errors)
          parsed << constraint if constraint
        when "forced"
          constraint = parse_forced_constraint(raw_constraint, index, parameters, errors)
          parsed << constraint if constraint
        when "higher_order"
          constraint = parse_higher_order_constraint(raw_constraint, index, parameters, errors)
          parsed << constraint if constraint
        else
          errors << "`constraints[#{index}]` has unknown type `#{raw_constraint['type']}`."
        end
      end
      parsed
    end

    def parse_conditional_constraint(raw_constraint, index, parameters, errors)
      parent = Lattice.normalize_scalar(raw_constraint["parent"])
      parameter_name = Lattice.normalize_scalar(raw_constraint["parameter"])
      values = parse_values(raw_constraint["values"], "`constraints[#{index}].values`", errors)
      applies_when = parse_values(raw_constraint["applies_when"], "`constraints[#{index}].applies_when`", errors)

      unless parameters.key?(parent)
        errors << "`constraints[#{index}]` references unknown parent parameter `#{parent}`."
        return nil
      end
      unless parameters.key?(parameter_name)
        errors << (
          "`constraints[#{index}]` references unknown conditional parameter `#{parameter_name}`. " \
          "`conditional` must define a child parameter with `values` and a parent gate. " \
          "For exclusions or requirements between existing parameters, use `invalid_pair`, " \
          "`higher_order`, `forward_dep`, or `bidirectional`; run `lattice agent instructions` " \
          "for the full schema reference."
        )
        return nil
      end

      parent_parameter = parameters[parent]
      missing = applies_when.reject { |value| parent_parameter.value_set.include?(value) }
      unless missing.empty?
        errors << "`constraints[#{index}]` applies_when contains unknown values for `#{parent}`: #{missing.join(', ')}."
        return nil
      end

      return nil if values.empty?

      ConditionalConstraint.new(
        parameter: parameter_name,
        values: values.reject { |value| value == NA_VALUE },
        parent:,
        applies_when:
      )
    end

    def parse_forced_constraint(raw_constraint, index, parameters, errors)
      assignments = raw_constraint["assignments"]
      unless assignments.is_a?(Array) && !assignments.empty?
        errors << "`constraints[#{index}].assignments` must contain at least one assignment."
        return nil
      end

      seen_parameters = Set.new
      parsed_assignments = []
      assignments.each_with_index do |raw_assignment, assignment_index|
        assignment = parse_assignment(
          raw_assignment,
          parameters,
          "`constraints[#{index}].assignments[#{assignment_index}]`",
          errors
        )
        next if assignment.nil?

        if seen_parameters.include?(assignment.parameter)
          errors << "`constraints[#{index}]` repeats parameter `#{assignment.parameter}` inside a forced interaction."
          next
        end
        seen_parameters.add(assignment.parameter)
        parsed_assignments << assignment
      end
      return nil if parsed_assignments.empty?

      ForcedConstraint.new(assignments: parsed_assignments)
    end

    def parse_higher_order_constraint(raw_constraint, index, parameters, errors)
      if_all = raw_constraint["if_all"]
      unless if_all.is_a?(Array) && if_all.length >= 2
        errors << "`constraints[#{index}].if_all` must contain at least two assignments."
        return nil
      end

      parsed_if_all = if_all.each_with_index.filter_map do |raw_assignment, assignment_index|
        parse_assignment(raw_assignment, parameters, "`constraints[#{index}].if_all[#{assignment_index}]`", errors)
      end
      parsed_then_not = parse_assignment(raw_constraint["then_not"], parameters, "`constraints[#{index}].then_not`", errors)
      return nil unless !parsed_if_all.empty? && parsed_then_not

      HigherOrderConstraint.new(if_all: parsed_if_all, then_not: parsed_then_not)
    end

    def parse_assignment(raw_assignment, parameters, field_name, errors)
      unless raw_assignment.is_a?(Hash)
        errors << "#{field_name} must be an object."
        return nil
      end

      parameter_name = Lattice.normalize_scalar(raw_assignment["parameter"])
      value = Lattice.normalize_scalar(raw_assignment["value"])

      parameter = parameters[parameter_name]
      if parameter.nil?
        errors << "#{field_name} references unknown parameter `#{parameter_name}`."
        return nil
      end

      unless parameter.value_set.include?(value)
        errors << "#{field_name} references unknown value `#{value}` for parameter `#{parameter_name}`."
        return nil
      end

      Assignment.new(parameter: parameter_name, value:)
    end

    def parse_values(raw_values, field_name, errors)
      unless raw_values.is_a?(Array) && !raw_values.empty?
        errors << "#{field_name} must be a non-empty list."
        return []
      end

      values = raw_values.map { |value| Lattice.normalize_scalar(value) }
      if values.uniq.length != values.length
        errors << "#{field_name} contains duplicate values."
        return []
      end
      values
    end

    def parse_weights(raw_weights, values, parameter_name, errors)
      return nil if raw_weights.nil?

      unless raw_weights.is_a?(Array)
        errors << "`weights` for parameter `#{parameter_name}` must be a list."
        return nil
      end
      if raw_weights.length != values.length
        errors << "`weights` for parameter `#{parameter_name}` must have the same length as its values."
        return nil
      end

      parsed = []
      raw_weights.each do |weight|
        unless weight.is_a?(Numeric)
          errors << "`weights` for parameter `#{parameter_name}` must be numeric."
          return nil
        end
        unless weight.positive?
          errors << "`weights` for parameter `#{parameter_name}` must be greater than zero."
          return nil
        end
        parsed << weight.to_f
      end
      parsed
    end

    def parse_strength(raw_strength, parameter_count, errors)
      strength =
        case raw_strength
        when nil then 2
        when Numeric then raw_strength.to_i
        else
          begin
            Integer(raw_strength)
          rescue TypeError, ArgumentError
            errors << "`strength` must be an integer."
            return 2
          end
        end

      errors << "`strength` must be at least 1." if strength < 1
      errors << "`strength` cannot exceed the number of parameters." if parameter_count.positive? && strength > parameter_count
      strength
    end
  end
end
