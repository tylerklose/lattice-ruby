# frozen_string_literal: true

require_relative "lattice/version"
require_relative "lattice/model"
require_relative "lattice/parser"
require_relative "lattice/constraints"
require_relative "lattice/ipog"
require_relative "lattice/formatters"

module Lattice
  # A generation run: the parsed model plus its covering array, with
  # ready-to-use named scenarios for tests, fixtures, and factories.
  class Run
    attr_reader :model, :result, :seed

    def initialize(model:, result:, seed:)
      @model = model
      @result = result
      @seed = seed
    end

    # Scenarios as an array of `{ "parameter" => "value" }` hashes.
    def scenarios
      @scenarios ||= Formatters.named_rows(model, result).each(&:freeze).freeze
    end

    def each_scenario(&) = scenarios.each(&)

    def coverage_curve = result.coverage_curve

    def to_table = Formatters.render_output(model, result, output_format: "table", seed:)
    def to_json_output = Formatters.render_output(model, result, output_format: "json", seed:)
    def to_csv = Formatters.render_output(model, result, output_format: "csv", seed:)
    def to_summary = Formatters.render_output(model, result, output_format: "summary", seed:)
    def to_yaml_output = Formatters.render_output(model, result, output_format: "yaml", seed:)
  end

  class << self
    # Parse a schema from a Hash (already-decoded JSON/YAML), a JSON or YAML
    # String, or a file path via `file:`.
    def parse_model(source = nil, file: nil, strength: nil)
      if file
        Parser.load_model(file, strength_override: strength)
      elsif source.is_a?(Hash)
        Parser.parse_model_data(source, strength_override: strength)
      elsif source.is_a?(String)
        data = Parser.deserialize_model(source, "string", nil)
        Parser.parse_model_data(data, strength_override: strength)
      elsif source.is_a?(Model)
        strength ? source.with(strength:) : source
      else
        raise ArgumentError, "Pass a schema Hash, a JSON/YAML String, a Lattice::Model, or file: <path>."
      end
    end

    # Generate a covering array for a schema and return a Run.
    #
    #   run = Lattice.generate(file: "spec/fixtures/checkout.yaml")
    #   run.scenarios.each { |row| ... }
    def generate(source = nil, file: nil, strength: nil, seed: 42, pool_size: 50,
                 max_rows: nil, stop_after_coverage: nil, progress: nil)
      model = parse_model(source, file:, strength:)
      result = IPOG.generate_covering_array(
        model,
        strength: model.strength,
        seed:,
        pool_size:,
        progress:,
        max_rows:,
        stop_after_coverage:
      )
      Run.new(model:, result:, seed:)
    end

    # Convenience: generate and return just the named scenario hashes.
    def scenarios(...) = generate(...).scenarios

    # Parse and constraint-check a schema, raising Lattice::ValidationError or
    # Lattice::ConstraintError when invalid. Returns the Model.
    def validate!(source = nil, file: nil, strength: nil)
      model = parse_model(source, file:, strength:)
      engine = ConstraintEngine.new(model)
      raise ValidationError, ["Model has no valid complete assignments."] unless engine.can_complete?({})

      model
    end
  end
end
