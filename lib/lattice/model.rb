# frozen_string_literal: true

require "set"

module Lattice
  NA_VALUE = "N/A"

  def self.normalize_scalar(value)
    value.nil? ? "null" : value.to_s
  end

  Assignment = Data.define(:parameter, :value) do
    include Comparable

    def <=>(other)
      [parameter, value] <=> [other.parameter, other.value]
    end
  end

  class Parameter
    attr_reader :name, :values, :weights

    def initialize(name:, values:, weights: nil)
      @name = name
      @values = values.to_a.freeze
      @weights = weights&.to_a&.freeze
    end

    def value_set
      @value_set ||= Set.new(values).freeze
    end

    # Weight normalization mirrors the Python implementation, including its
    # naive left-to-right float summation, so scores tie-break identically.
    def normalized_weights
      @normalized_weights ||=
        if weights.nil?
          Array.new(values.length, 1.0 / values.length).freeze
        else
          total = weights.inject(0.0) { |acc, weight| acc + weight }
          if total <= 0
            Array.new(values.length, 1.0 / values.length).freeze
          else
            weights.map { |weight| weight / total }.freeze
          end
        end
    end
  end

  InvalidPairConstraint = Data.define(:if_assignment, :then_not)
  BidirectionalConstraint = Data.define(:pair)
  ForwardDependencyConstraint = Data.define(:source, :target)
  ConditionalConstraint = Data.define(:parameter, :values, :parent, :applies_when)
  ForcedConstraint = Data.define(:assignments)
  HigherOrderConstraint = Data.define(:if_all, :then_not)

  class Model
    attr_reader :model_name, :parameters, :constraints, :strength

    def initialize(model_name:, parameters:, constraints:, strength: 2)
      @model_name = model_name
      @parameters = parameters.to_a.freeze
      @constraints = constraints.to_a.freeze
      @strength = strength
    end

    def parameter_names
      @parameter_names ||= parameters.map(&:name).freeze
    end

    def parameter_lookup
      @parameter_lookup ||= parameters.to_h { |parameter| [parameter.name, parameter] }.freeze
    end

    def exhaustive_count
      @exhaustive_count ||= parameters.inject(1) { |total, parameter| total * parameter.values.length }
    end

    def with(strength:)
      Model.new(model_name:, parameters:, constraints:, strength:)
    end
  end
end
