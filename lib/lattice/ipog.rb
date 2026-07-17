# frozen_string_literal: true

require "set"

require_relative "constraints"
require_relative "mersenne_twister"

module Lattice
  CoveragePoint = Data.define(:scenario, :cumulative_pct)
  GenerationResult = Data.define(:rows, :coverage_curve, :total_valid_tuples)
  GenerationProgress = Data.define(:event, :scenario, :covered, :total, :cumulative_pct, :uncovered)

  # Greedy covering-array generation (IPOG-style): enumerate every valid
  # t-way interaction, then repeatedly extend the lowest uncovered tuple into
  # the highest-scoring full row from a seeded candidate pool. Deterministic
  # for a given seed, and row-for-row identical to the Python implementation.
  module IPOG
    extend self

    def generate_covering_array(
      model,
      strength: nil,
      seed: 42,
      pool_size: 50,
      progress: nil,
      max_rows: nil,
      stop_after_coverage: nil
    )
      actual_strength = strength || model.strength
      raise ArgumentError, "`pool_size` must be at least 1." if pool_size < 1
      raise ArgumentError, "`max_rows` must be at least 1." if !max_rows.nil? && max_rows < 1

      coverage_target = coverage_target_for(stop_after_coverage)

      engine = ConstraintEngine.new(model)
      raise ArgumentError, "Model has no valid full assignments." unless engine.can_complete?({})

      valid_tuples = enumerate_valid_tuples(model, engine, actual_strength, progress:)
      uncovered = Set.new(valid_tuples)
      rows = []
      coverage_points = []
      rng = MersenneTwister.new(seed)
      limit_reached = false
      progress&.call(
        GenerationProgress.new(
          event: "enumerated",
          scenario: 0,
          covered: 0,
          total: valid_tuples.length,
          cumulative_pct: coverage_pct(0, valid_tuples.length),
          uncovered: uncovered.length
        )
      )

      record_row = lambda do |row|
        newly_covered = covered_tuples(row, actual_strength, uncovered)
        rows << row
        uncovered.subtract(newly_covered)
        covered = valid_tuples.length - uncovered.length
        cumulative_pct = coverage_pct(covered, valid_tuples.length)
        coverage_points << CoveragePoint.new(scenario: rows.length, cumulative_pct:)
        progress&.call(
          GenerationProgress.new(
            event: "scenario",
            scenario: rows.length,
            covered:,
            total: valid_tuples.length,
            cumulative_pct:,
            uncovered: uncovered.length
          )
        )
        if should_stop?(rows.length, cumulative_pct, max_rows, coverage_target)
          progress&.call(
            GenerationProgress.new(
              event: "stopped",
              scenario: rows.length,
              covered:,
              total: valid_tuples.length,
              cumulative_pct:,
              uncovered: uncovered.length
            )
          )
          true
        else
          false
        end
      end

      engine.forced_interactions.each do |forced|
        partial = forced.to_h { |parameter_index, value_index| [parameter_index, value_index] }
        row = best_candidate_row(model, engine, partial, uncovered, actual_strength, pool_size, rng)
        next if row.nil? || rows.include?(row)

        if record_row.call(row)
          limit_reached = true
          break
        end
      end

      while !uncovered.empty? && !limit_reached
        seed_tuple = uncovered.min
        partial = seed_tuple.to_h { |parameter_index, value_index| [parameter_index, value_index] }
        row = best_candidate_row(model, engine, partial, uncovered, actual_strength, pool_size, rng)
        raise "Unable to complete uncovered tuple: #{seed_tuple.inspect}" if row.nil?

        if record_row.call(row)
          limit_reached = true
          break
        end
      end

      GenerationResult.new(
        rows: rows.freeze,
        coverage_curve: coverage_points.freeze,
        total_valid_tuples: valid_tuples.length
      )
    end

    def enumerate_valid_tuples(model, engine, strength, progress: nil)
      tuples = []
      total_candidates = candidate_tuple_count(model, strength)
      checked = 0
      report = lambda do
        progress&.call(
          GenerationProgress.new(
            event: "enumerating",
            scenario: 0,
            covered: checked,
            total: total_candidates,
            cumulative_pct: coverage_pct(checked, total_candidates),
            uncovered: [0, total_candidates - checked].max
          )
        )
      end

      (0...model.parameters.length).to_a.combination(strength) do |parameter_combo|
        domains = parameter_combo.map { |parameter_index| (0...model.parameters[parameter_index].values.length).to_a }
        domains[0].product(*domains[1..]) do |value_combo|
          checked += 1
          partial = parameter_combo.each_with_index.to_h { |parameter_index, offset| [parameter_index, value_combo[offset]] }
          tuples << parameter_combo.zip(value_combo) if engine.can_complete?(partial)
          report.call if progress && (checked % 1000).zero?
        end
      end
      report.call if progress
      tuples
    end

    def candidate_tuple_count(model, strength)
      total = 0
      (0...model.parameters.length).to_a.combination(strength) do |parameter_combo|
        total += parameter_combo.inject(1) { |count, parameter_index| count * model.parameters[parameter_index].values.length }
      end
      total
    end

    def coverage_target_for(stop_after_coverage)
      return nil if stop_after_coverage.nil?

      unless stop_after_coverage.positive? && stop_after_coverage <= 100
        raise ArgumentError, "`stop_after_coverage` must be in the range (0, 100]."
      end
      return nil if stop_after_coverage >= 100

      stop_after_coverage
    end

    def should_stop?(row_count, cumulative_pct, max_rows, coverage_target)
      return true if !max_rows.nil? && row_count >= max_rows
      return true if !coverage_target.nil? && cumulative_pct >= coverage_target

      false
    end

    def best_candidate_row(model, engine, partial, uncovered, strength, pool_size, rng)
      candidates = {}
      deterministic = engine.complete_assignment(partial, rng: nil)
      candidates[deterministic] = score_row(model, deterministic, uncovered, strength) unless deterministic.nil?

      (pool_size - 1).times do
        attempt_rng = MersenneTwister.new(rng.getrandbits(64))
        candidate = engine.complete_assignment(partial, rng: attempt_rng)
        next if candidate.nil?

        score = score_row(model, candidate, uncovered, strength)
        previous = candidates[candidate]
        candidates[candidate] = score if previous.nil? || (score <=> previous).positive?
      end

      return nil if candidates.empty?

      candidates.max_by { |row, score| [score[0], score[1], reverse_lex(row)] }[0]
    end

    def score_row(model, row, uncovered, strength)
      newly_covered = covered_tuples(row, strength, uncovered).length
      weight_score = row.each_with_index.inject(0.0) do |acc, (value_index, parameter_index)|
        acc + model.parameters[parameter_index].normalized_weights[value_index]
      end
      [newly_covered, weight_score]
    end

    def covered_tuples(row, strength, candidate_tuples)
      covered = Set.new
      (0...row.length).to_a.combination(strength) do |parameter_combo|
        tuple_key = parameter_combo.map { |parameter_index| [parameter_index, row[parameter_index]] }
        covered.add(tuple_key) if candidate_tuples.include?(tuple_key)
      end
      covered
    end

    def coverage_pct(covered_count, total_count)
      return 100.0 if total_count.zero?

      ((covered_count.to_f / total_count) * 100).round(1, half: :even)
    end

    def reverse_lex(row)
      row.map(&:-@)
    end
  end
end
