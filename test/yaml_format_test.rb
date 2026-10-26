# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "yaml"

# `--format yaml`: the same content as `--format json`, written by hand in one
# fixed style. test/fixtures/yaml_edges.golden.yaml pins the exact bytes for
# test/fixtures/yaml_edges.json; the Python implementation tests against the
# same pair.
class YamlFormatTest < Minitest::Test
  cover "Lattice::Formatters*"

  include FixtureHelpers

  ROOT = File.expand_path("..", __dir__)

  def generate(fixture, **options)
    model = load_fixture(fixture)
    result = Lattice::IPOG.generate_covering_array(model, strength: model.strength, seed: 42, pool_size: 50, **options)
    [model, result]
  end

  def test_edge_case_fixture_matches_golden_bytes
    model, result = generate("yaml_edges.json")
    golden = File.read(fixture_path("yaml_edges.golden.yaml"), encoding: "UTF-8")
    assert_equal golden, Lattice::Formatters.format_yaml(model, result, seed: 42) + "\n"
  end

  def test_yaml_reads_back_as_the_json_payload
    %w[simple.json constrained.json skillit.json yaml_edges.json].each do |fixture|
      model, result = generate(fixture)
      yaml = Lattice::Formatters.format_yaml(model, result, seed: 42)
      json = Lattice::Formatters.format_json(model, result, seed: 42)
      assert_equal JSON.parse(json), YAML.safe_load(yaml), "YAML and JSON disagree for #{fixture}"
    end
  end

  def test_empty_result_writes_empty_lists_and_null_seed
    model = load_fixture("simple.json")
    result = Lattice::GenerationResult.new(rows: [], coverage_curve: [], total_valid_tuples: 0)
    expected = <<~YAML.chomp
      meta:
        model_name: "simple"
        strength: 2
        test_count: 0
        exhaustive_count: 8
        reduction: "inf"
        coverage: "0.0%"
        seed: null
      coverage_curve: []
      scenarios: []
    YAML
    assert_equal expected, Lattice::Formatters.render_output(model, result, output_format: "yaml", seed: nil)
  end

  # Inputs are built from code points so the source stays ASCII.
  def uescape(hex) = %("\\u#{hex}")

  def test_yaml_string_escapes
    {
      "plain" => '"plain"',
      "" => '""',
      "yes" => '"yes"',
      "~" => '"~"',
      " " => '" "',
      'say "hi"' => '"say \"hi\""',
      'back\slash' => '"back\\\\slash"',
      [0x08] => '"\b"',
      [0x09] => '"\t"',
      [0x0a] => '"\n"',
      [0x0c] => '"\f"',
      [0x0d] => '"\r"',
      [0x00] => uescape("0000"),
      [0x07] => uescape("0007"),
      [0x0b] => uescape("000b"),
      [0x1f] => uescape("001f"),
      [0x7e] => '"~"',
      [0x7f] => uescape("007f"),
      [0x80] => uescape("0080"),
      [0x85] => uescape("0085"),
      [0x9f] => uescape("009f"),
      [0xa0] => [0x22, 0xa0, 0x22],
      [0x63, 0x61, 0x66, 0xe9] => [0x22, 0x63, 0x61, 0x66, 0xe9, 0x22],
      [0x2027] => [0x22, 0x2027, 0x22],
      [0x2028] => uescape("2028"),
      [0x2029] => uescape("2029"),
      [0x202a] => [0x22, 0x202a, 0x22],
      [0xfeff] => uescape("feff"),
      [0xfffd] => [0x22, 0xfffd, 0x22],
      [0xfffe] => uescape("fffe"),
      [0xffff] => uescape("ffff"),
      [0x1f600] => [0x22, 0x1f600, 0x22]
    }.each do |input, expected|
      input = input.pack("U*") if input.is_a?(Array)
      expected = expected.pack("U*") if expected.is_a?(Array)
      assert_equal expected, Lattice::Formatters.yaml_string(input), "escaping #{input.dump}"
    end
  end

  def test_run_to_yaml_output
    run = Lattice.generate(file: fixture_path("yaml_edges.json"))
    golden = File.read(fixture_path("yaml_edges.golden.yaml"), encoding: "UTF-8")
    assert_equal golden, run.to_yaml_output + "\n"
  end

  def test_cli_generate_format_yaml
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "lattice"),
      "generate", "--format", "yaml", fixture_path("yaml_edges.json")
    )
    assert_equal 0, status.exitstatus, stderr
    assert_equal File.binread(fixture_path("yaml_edges.golden.yaml")), stdout.b
  end
end
