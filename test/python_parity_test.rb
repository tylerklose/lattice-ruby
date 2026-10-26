# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# Cross-implementation contract: for the same schema, seed, and pool size, the
# Ruby and Python implementations must produce byte-identical output. Runs
# against the Python source checkout (LATTICE_PYTHON_SRC or ../lattice/src) or
# an installed `lattice-cli`; skips when no Python implementation is found.
class PythonParityTest < Minitest::Test
  include FixtureHelpers

  ROOT = File.expand_path("..", __dir__)

  def python_env
    @python_env ||= begin
      src = ENV.fetch("LATTICE_PYTHON_SRC", File.expand_path("../lattice/src", ROOT))
      python = ENV.fetch("LATTICE_PYTHON", "python3")
      probe = lambda do |env|
        _out, _err, status = Open3.capture3(env, python, "-c", "import lattice", stdin_data: "")
        status.success?
      end
      if File.directory?(src) && probe.call({ "PYTHONPATH" => src })
        [python, { "PYTHONPATH" => src }]
      elsif probe.call({})
        [python, {}]
      end
    end
  end

  def run_python(*args, stdin_data:)
    python, env = python_env
    Open3.capture3(env, python, "-m", "lattice", *args, stdin_data:)
  end

  def run_ruby(*args, stdin_data:)
    Open3.capture3(
      RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "lattice"), *args,
      stdin_data:
    )
  end

  def assert_parity(*args, fixture:)
    skip "Python lattice implementation not available" unless python_env

    stdin_data = File.read(fixture_path(fixture))
    python_out, python_err, python_status = run_python(*args, stdin_data:)
    ruby_out, ruby_err, ruby_status = run_ruby(*args, stdin_data:)

    assert_equal python_status.exitstatus, ruby_status.exitstatus,
                 "exit codes diverged (python stderr: #{python_err}; ruby stderr: #{ruby_err})"
    assert_equal python_out, ruby_out, "output diverged for `lattice #{args.join(' ')}` on #{fixture}"
  end

  %w[simple.json constrained.json skillit.json yaml_edges.json].each do |fixture|
    fixture_slug = fixture.sub(".json", "").tr(".-", "_")

    define_method("test_generate_json_parity_#{fixture_slug}") do
      assert_parity("generate", fixture: fixture)
    end

    define_method("test_generate_table_parity_#{fixture_slug}") do
      assert_parity("generate", "--format", "table", fixture: fixture)
    end

    define_method("test_generate_csv_parity_#{fixture_slug}") do
      assert_parity("generate", "--format", "csv", fixture: fixture)
    end

    define_method("test_generate_summary_parity_#{fixture_slug}") do
      assert_parity("generate", "--format", "summary", fixture: fixture)
    end

    define_method("test_generate_yaml_parity_#{fixture_slug}") do
      assert_parity("generate", "--format", "yaml", fixture: fixture)
    end
  end

  def test_generate_parity_with_alternate_seed_and_pool
    assert_parity("generate", "--seed", "7", "--pool-size", "5", fixture: "constrained.json")
  end

  def test_generate_parity_with_strength_three
    assert_parity("generate", "--strength", "3", fixture: "simple.json")
  end

  def test_generate_parity_with_max_rows
    assert_parity("generate", "--max-rows", "3", fixture: "simple.json")
  end

  def test_generate_parity_with_stop_after_coverage
    assert_parity("generate", "--stop-after-coverage", "75", fixture: "constrained.json")
  end

  def test_generate_parity_with_weights_fixture
    assert_parity("generate", fixture: "skillit.json")
  end

  def test_validate_parity
    assert_parity("validate", fixture: "constrained.json")
  end

  def test_validation_error_parity
    assert_parity("validate", fixture: "invalid.json")
  end
end
