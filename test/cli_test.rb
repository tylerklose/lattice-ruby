# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class CliTest < Minitest::Test
  include FixtureHelpers

  ROOT = File.expand_path("..", __dir__)

  def run_cli(*args, stdin_data: nil)
    Open3.capture3(
      RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "lattice"), *args,
      stdin_data: stdin_data || ""
    )
  end

  def test_generate_json_from_file
    stdout, _stderr, status = run_cli("generate", fixture_path("simple.json"))
    assert_equal 0, status.exitstatus
    payload = JSON.parse(stdout)
    assert_equal "simple", payload["meta"]["model_name"]
    refute_empty payload["scenarios"]
  end

  def test_generate_reads_stdin
    stdout, _stderr, status = run_cli("generate", "--format", "csv", stdin_data: File.read(fixture_path("simple.json")))
    assert_equal 0, status.exitstatus
    refute_empty stdout
  end

  def test_generate_table_and_summary_formats
    %w[table summary].each do |format|
      stdout, _stderr, status = run_cli("generate", "--format", format, fixture_path("simple.json"))
      assert_equal 0, status.exitstatus
      assert_includes stdout, "Lattice —"
    end
  end

  def test_validate_reports_schema_stats
    stdout, _stderr, status = run_cli("validate", fixture_path("constrained.json"))
    assert_equal 0, status.exitstatus
    payload = JSON.parse(stdout)
    assert_equal "ok", payload["status"]
    assert payload["valid"]
  end

  def test_invalid_schema_exits_one_with_json_errors
    stdout, _stderr, status = run_cli("validate", fixture_path("invalid.json"))
    assert_equal 1, status.exitstatus
    payload = JSON.parse(stdout)
    assert_equal "error", payload["status"]
    assert_equal "validation_error", payload["code"]
    refute_empty payload["errors"]
  end

  def test_missing_file_exits_two
    _stdout, _stderr, status = run_cli("validate", "--format", "text", "no_such_file.json")
    assert_equal 2, status.exitstatus
  end

  def test_agent_instructions
    stdout, _stderr, status = run_cli("agent", "instructions")
    assert_equal 0, status.exitstatus
    assert_includes stdout, "Lattice Agent Instructions"
  end

  def test_agent_install_generic_skill
    Dir.mktmpdir do |dir|
      target = File.join(dir, "skills", "lattice-workflow")
      stdout, _stderr, status = run_cli("agent", "install-skill", target, "--format", "json")
      assert_equal 0, status.exitstatus
      payload = JSON.parse(stdout)
      assert_equal "ok", payload["status"]
      assert File.file?(File.join(target, "SKILL.md"))
    end
  end

  def test_unknown_command_exits_two
    _stdout, _stderr, status = run_cli("frobnicate")
    assert_equal 2, status.exitstatus
  end
end
