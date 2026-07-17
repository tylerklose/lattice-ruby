# frozen_string_literal: true

# Regenerates the golden parity fixtures consumed by test/golden_parity_test.rb.
#
# Runs the Lattice CLI's generate command for every row of
# test/fixtures/generation_surface.lattice.yaml and snapshots stdout. Goldens
# are authored by the reference Python implementation:
#
#   LATTICE_PYTHON_SRC=~/development/lattice/src ruby test/support/generate_goldens.rb
#
# (defaults to ../lattice/src relative to this repo).

require "fileutils"
require "json"
require "open3"

ROOT = File.expand_path("../..", __dir__)
FIXTURES = File.join(ROOT, "test", "fixtures")
GOLDEN_DIR = File.join(FIXTURES, "golden")
SURFACE_SCHEMA = File.join(FIXTURES, "generation_surface.lattice.yaml")

PYTHON_SRC = ENV.fetch("LATTICE_PYTHON_SRC", File.expand_path("../lattice/src", ROOT))
PYTHON = ENV.fetch("LATTICE_PYTHON", "python3")

SCHEMA_FILES = { "simple" => "simple.json", "constrained" => "constrained.json", "skillit" => "skillit.json" }.freeze
SEEDS = { "default" => 42, "alt" => 7 }.freeze
POOL_SIZES = { "minimal" => 1, "default" => 50 }.freeze
MAX_ROWS_LIMIT = 3
STOP_PCT_LIMIT = 75.0

def cli_args(values)
  args = [File.join(FIXTURES, SCHEMA_FILES.fetch(values.fetch("schema")))]
  args += ["--strength", values.fetch("strength")]
  args += ["--seed", SEEDS.fetch(values.fetch("seed")).to_s]
  args += ["--pool-size", POOL_SIZES.fetch(values.fetch("pool_size")).to_s]
  case values.fetch("row_limit")
  when "max_rows" then args += ["--max-rows", MAX_ROWS_LIMIT.to_s]
  when "stop_pct" then args += ["--stop-after-coverage", STOP_PCT_LIMIT.to_s]
  end
  args + ["--format", values.fetch("format")]
end

surface_json, status = Open3.capture2(
  RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "lattice"),
  "generate", SURFACE_SCHEMA
)
abort "failed to generate option-surface rows" unless status.success?
scenarios = JSON.parse(surface_json).fetch("scenarios")

FileUtils.rm_rf(GOLDEN_DIR)
FileUtils.mkdir_p(GOLDEN_DIR)

manifest = scenarios.map do |scenario|
  values = scenario.fetch("values")
  slug = format(
    "%02d_%s_s%s_%s_pool_%s_%s_%s",
    scenario.fetch("id"), values["schema"], values["strength"],
    values["seed"], values["pool_size"], values["row_limit"], values["format"]
  )
  stdout, stderr, run_status = Open3.capture3(
    { "PYTHONPATH" => PYTHON_SRC },
    PYTHON, "-m", "lattice", "generate", *cli_args(values)
  )
  abort "python generate failed for #{slug}: #{stderr}" unless run_status.success?

  File.write(File.join(GOLDEN_DIR, "#{slug}.golden"), stdout)
  puts "wrote #{slug}.golden (#{stdout.bytesize} bytes)"
  { "id" => scenario.fetch("id"), "slug" => slug, "values" => values }
end

File.write(File.join(GOLDEN_DIR, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
puts "wrote manifest.json (#{manifest.length} configurations)"

# --- Validation-error goldens: Python's `validate --format json` output for
# every invalid fixture, asserted in-process by test/validation_errors_test.rb.

ERRORS_DIR = File.join(GOLDEN_DIR, "errors")
FileUtils.mkdir_p(ERRORS_DIR)

Dir[File.join(FIXTURES, "invalid", "*.json")].sort.each do |fixture|
  name = File.basename(fixture, ".json")
  stdout, stderr, run_status = Open3.capture3(
    { "PYTHONPATH" => PYTHON_SRC },
    PYTHON, "-m", "lattice", "validate", "--format", "json", fixture
  )
  abort "expected #{name} to be invalid, got exit 0: #{stdout}" if run_status.success?
  abort "python validate crashed for #{name}: #{stderr}" if stdout.strip.empty?

  File.write(File.join(ERRORS_DIR, "#{name}.json"), stdout)
  puts "wrote errors/#{name}.json"
end

# --- Progress-event goldens: the exact GenerationProgress sequences emitted by
# the Python implementation, asserted in-process by test/progress_events_test.rb.

PROGRESS_CONFIGS = [
  { "name" => "simple_default", "fixture" => "simple.json", "kwargs" => {} },
  { "name" => "constrained_max_rows", "fixture" => "constrained.json", "kwargs" => { "max_rows" => 3 } },
  { "name" => "skillit_s3_stop_pct", "fixture" => "skillit.json",
    "kwargs" => { "strength" => 3, "stop_after_coverage" => 75.0, "pool_size" => 5 } },
  { "name" => "simple_stop_pct_100", "fixture" => "simple.json",
    "kwargs" => { "stop_after_coverage" => 100.0 } }
].freeze

progress_script = <<~PYTHON
  import dataclasses, json, sys
  from lattice.parser import load_model
  from lattice.ipog import generate_covering_array

  config = json.loads(sys.argv[1])
  events = []
  model = load_model(config["fixture"])
  generate_covering_array(
      model,
      progress=lambda p: events.append(dataclasses.asdict(p)),
      **config["kwargs"],
  )
  print(json.dumps(events, indent=2))
PYTHON

PROGRESS_CONFIGS.each do |config|
  payload = { "fixture" => File.join(FIXTURES, config.fetch("fixture")), "kwargs" => config.fetch("kwargs") }
  stdout, stderr, run_status = Open3.capture3(
    { "PYTHONPATH" => PYTHON_SRC },
    PYTHON, "-c", progress_script, JSON.generate(payload)
  )
  abort "python progress capture failed for #{config.fetch('name')}: #{stderr}" unless run_status.success?

  File.write(File.join(GOLDEN_DIR, "progress_#{config.fetch('name')}.json"), stdout)
  puts "wrote progress_#{config.fetch('name')}.json"
end
