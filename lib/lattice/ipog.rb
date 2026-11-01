# frozen_string_literal: true

require_relative "constraints"

module Lattice
  CoveragePoint = Data.define(:scenario, :cumulative_pct)
  GenerationResult = Data.define(:rows, :coverage_curve, :total_valid_tuples)
  GenerationProgress = Data.define(:event, :scenario, :covered, :total, :cumulative_pct, :uncovered)

  # Scenario generation, backed by the Rust engine (Lattice::Engine, built from
  # ext/lattice_native on the lattice-engine crate). The engine builds a covering
  # array greedily, choosing each row from several candidates, then shrinks it
  # with tabu search, and returns the rows ordered so each adds the most new
  # coverage. ConstraintEngine compiles the model into the engine's input; this
  # module applies max_rows and stop_after_coverage by cutting the ordered rows
  # short. Python's lattice.ipog does the same, so both give identical rows.
  module IPOG
    extend self

    DEFAULT_CANDIDATES = 16
    SHRINK_STEPS = 1_000_000
    PATIENCE = 10_000
    SEED_MODULUS = 2**64

    # `pool_size` is the number of candidate rows built per greedy step.
    def generate_covering_array(
      model,
      strength: nil,
      seed: 42,
      pool_size: DEFAULT_CANDIDATES,
      progress: nil,
      max_rows: nil,
      stop_after_coverage: nil
    )
      actual_strength = strength || model.strength
      raise ArgumentError, "`pool_size` must be at least 1." if pool_size < 1
      raise ArgumentError, "`max_rows` must be at least 1." if !max_rows.nil? && max_rows < 1

      coverage_target = coverage_target_for(stop_after_coverage)

      engine = ConstraintEngine.new(model)
      raise ArgumentError, "Model has no valid full assignments." unless engine.satisfiable?

      native = actual_strength == model.strength ? engine.native : engine.native_model(actual_strength)
      rows, new_coverage, total = native.generate(seed % SEED_MODULUS, pool_size, SHRINK_STEPS, PATIENCE)

      report(progress, "enumerated", 0, 0, total)
      kept = []
      curve = []
      covered = 0
      rows.zip(new_coverage) do |row, gained|
        kept << row.freeze
        covered += gained
        cumulative_pct = coverage_pct(covered, total)
        curve << CoveragePoint.new(scenario: kept.length, cumulative_pct:)
        report(progress, "scenario", kept.length, covered, total)
        next unless should_stop?(kept.length, cumulative_pct, max_rows, coverage_target)

        report(progress, "stopped", kept.length, covered, total) if kept.length < rows.length
        break
      end

      GenerationResult.new(rows: kept.freeze, coverage_curve: curve.freeze, total_valid_tuples: total)
    end

    private

    def report(progress, event, scenario, covered, total)
      progress&.call(
        GenerationProgress.new(
          event:,
          scenario:,
          covered:,
          total:,
          cumulative_pct: coverage_pct(covered, total),
          uncovered: total - covered
        )
      )
    end

    def coverage_target_for(stop_after_coverage)
      return nil if stop_after_coverage.nil?

      unless stop_after_coverage.positive? && stop_after_coverage <= 100
        raise ArgumentError, "`stop_after_coverage` must be in the range (0, 100]."
      end

      stop_after_coverage
    end

    def should_stop?(row_count, cumulative_pct, max_rows, coverage_target)
      return true if !max_rows.nil? && row_count >= max_rows
      return true if !coverage_target.nil? && cumulative_pct >= coverage_target

      false
    end

    # A satisfiable model always has valid tuples, so total_count is positive.
    def coverage_pct(covered_count, total_count)
      ((covered_count.to_f / total_count) * 100).round(1, half: :even)
    end
  end
end
