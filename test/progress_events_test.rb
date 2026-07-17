# frozen_string_literal: true

require_relative "test_helper"

# Asserts the exact GenerationProgress event sequences against goldens captured
# from the Python implementation (test/support/generate_goldens.rb).
class ProgressEventsTest < Minitest::Test
  cover "Lattice::IPOG*"
  cover "Lattice::ConstraintEngine*"

  include FixtureHelpers

  GOLDEN_DIR = File.join(FixtureHelpers::FIXTURES, "golden")

  CONFIGS = {
    "simple_default" => ["simple.json", {}],
    "constrained_max_rows" => ["constrained.json", { max_rows: 3 }],
    "skillit_s3_stop_pct" => ["skillit.json", { strength: 3, stop_after_coverage: 75.0, pool_size: 5 }]
  }.freeze

  CONFIGS.each do |name, (fixture, kwargs)|
    define_method("test_progress_events_#{name}") do
      events = []
      collector = lambda do |progress|
        events << {
          "event" => progress.event,
          "scenario" => progress.scenario,
          "covered" => progress.covered,
          "total" => progress.total,
          "cumulative_pct" => progress.cumulative_pct,
          "uncovered" => progress.uncovered
        }
      end

      Lattice::IPOG.generate_covering_array(load_fixture(fixture), progress: collector, **kwargs)

      golden = JSON.parse(File.read(File.join(GOLDEN_DIR, "progress_#{name}.json")))
      assert_equal golden, events, "progress event sequence diverged for #{name}"
    end
  end
end
