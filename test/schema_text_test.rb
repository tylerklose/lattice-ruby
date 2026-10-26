# frozen_string_literal: true

require_relative "test_helper"

# Schema values keep the text the user wrote (Lattice::SchemaText). The Python
# implementation runs the same cases in tests/test_schema_text.py, and
# test/fixtures/scalar_text.* is shared between the two.
class SchemaTextTest < Minitest::Test
  cover "Lattice::SchemaText*"
  cover "Lattice::Parser*"

  include FixtureHelpers

  def values(model)
    model.parameters.to_h { |parameter| [parameter.name, parameter.values] }
  end

  def test_yaml_fixture_keeps_value_text
    model = Lattice::Parser.load_model(fixture_path("scalar_text.yaml"))
    assert_equal(
      {
        "numbers" => ["1.10", "0x1F", "012", "1_000", "1e3", "1.0e+20", ".inf", "-.inf", ".nan", "1:30", "+12", "-0"],
        "times" => ["2026-10-26", "2026-10-26 10:00:00", "2026-10-26T10:00:00Z", "2026-10-26T10:00:00+02:00"],
        "words" => %w[true false null yEs nO y yes],
        "tagged" => ["=", "<<", "yes", "07", "1.5"],
        "1.10" => %w[x y],
        "true" => %w[p q],
        "weighted" => %w[a b],
        "merged" => %w[c d]
      },
      values(model)
    )
    assert_equal [0.7, 3.0], model.parameter_lookup["merged"].weights
  end

  def test_yaml_fixture_output_matches_golden
    model = Lattice::Parser.load_model(fixture_path("scalar_text.yaml"))
    result = Lattice::IPOG.generate_covering_array(model, strength: model.strength, seed: 42, pool_size: 50)
    assert_equal File.read(fixture_path("scalar_text.golden.json")),
                 Lattice::Formatters.format_json(model, result, seed: 42) + "\n"
  end

  def test_json_fixture_keeps_number_text
    model = Lattice::Parser.load_model(fixture_path("scalar_text.json"))
    assert_equal(
      {
        "numbers" => ["1.10", "1e20", "1E5", "0", "100000000000000000000.0", "12", "0.1", "-2.50"],
        "literals" => ["true", "false", "null", "true!"],
        "weighted" => %w[a b]
      },
      values(model)
    )
    assert_equal [0.25, 2.0], model.parameter_lookup["weighted"].weights
  end

  def test_yaml_words
    words = %w[yes Yes YES true True TRUE on On ON no No NO false False FALSE off Off OFF ~ null Null NULL yEs nULL y n]
    expected = [true] * 9 + [false] * 9 + [nil] * 4 + %w[yEs nULL y n]
    assert_equal expected, Lattice::SchemaText.load_yaml("[#{words.join(', ')}]")
    assert_equal({ "a" => nil, "b" => "" }, Lattice::SchemaText.load_yaml("a:\nb: ''\n"))
    assert_equal %w[yes null on], Lattice::SchemaText.load_yaml(%(["yes", 'null', !!str on]))
    assert_equal ["true", "x"], Lattice::SchemaText.load_yaml("[! true, ! x]")
    assert_equal [true, "maybe"], Lattice::SchemaText.load_yaml("[!!bool yes, !!bool maybe]")
  end

  def test_yaml_block_and_folded_scalars_keep_text
    assert_equal({ "a" => "yes\n", "b" => "1.10\n" }, Lattice::SchemaText.load_yaml("a: |\n  yes\nb: >\n  1.10\n"))
  end

  def test_yaml_empty_document
    assert_nil Lattice::SchemaText.load_yaml("")
    assert_nil Lattice::SchemaText.load_yaml("# only a comment\n")
  end

  def test_yaml_aliases_and_merges
    yaml = <<~YAML
      base: &base {x: 1, y: 2}
      other: &other {y: 3, z: 4}
      list: &list [a, b]
      copy: *list
      one: {<<: *base, x: 9}
      many: {<<: [*base, *other], w: 0}
    YAML
    data = Lattice::SchemaText.load_yaml(yaml)
    assert_equal %w[a b], data["copy"]
    assert_equal({ "x" => "9", "y" => "2" }, data["one"])
    assert_equal({ "x" => "1", "y" => "2", "z" => "4", "w" => "0" }, data["many"])
    assert_equal %w[x y z w], data["many"].keys
  end

  def test_yaml_merge_key_must_be_plain_untagged_or_merge_tagged
    assert_equal({ "<<" => { "x" => "1" } }, Lattice::SchemaText.load_yaml(%({"<<": {x: 1}})))
    assert_equal({ "<<" => { "x" => "1" } }, Lattice::SchemaText.load_yaml("{!!str <<: {x: 1}}"))
    assert_equal({ "x" => "1" }, Lattice::SchemaText.load_yaml("{!!merge <<: {x: 1}}"))
  end

  def test_yaml_alias_as_key
    assert_equal({ "k" => "x", "map" => { "x" => "1" } }, Lattice::SchemaText.load_yaml("k: &m x\nmap: {*m : 1}\n"))
  end

  def test_yaml_errors
    {
      "a: 1\na: 2\n" => "duplicate key `a`",
      "yes: 1\nYES: 2\n" => "duplicate key `true`",
      "~: 1\nnull: 2\n" => "duplicate key `null`",
      "a: 1\n---\nb: 2\n" => "expected a single YAML document, found 2",
      "a: !foo x\n" => "unsupported YAML tag `!foo`",
      "a: !!set {x}\n" => "unsupported YAML tag `tag:yaml.org,2002:set`",
      "a: !!omap [x: 1]\n" => "unsupported YAML tag `tag:yaml.org,2002:omap`",
      "? [a]\n: b\n" => "mapping keys must be scalars",
      "? {a: 1}\n: b\n" => "mapping keys must be scalars",
      "a: {<<: [{x: 1}, y]}\n" => "merge key `<<` needs a mapping or a list of mappings",
      "a: {<<: [[{x: 1}]]}\n" => "merge key `<<` needs a mapping or a list of mappings",
      "a: {<<: [x]}\n" => "merge key `<<` needs a mapping or a list of mappings",
      "a: {<<: {x: 1}, <<: {y: 2}}\n" => "duplicate key `<<`",
      "a: &r [*r]\n" => "recursive alias",
      "a: *nope\n" => "unknown alias `*nope`"
    }.each do |yaml, message|
      error = assert_raises(Lattice::SchemaText::SyntaxError, yaml) { Lattice::SchemaText.load_yaml(yaml) }
      assert_equal message, error.message, yaml
    end
  end

  def test_json_errors
    error = assert_raises(JSON::ParserError) { Lattice::SchemaText.load_json(%({"a": 1, "a": 2})) }
    assert_match(/duplicate key .a/, error.message)
    assert_raises(JSON::ParserError) { Lattice::SchemaText.load_json("[NaN]") }
    assert_raises(JSON::ParserError) { Lattice::SchemaText.load_json("[Infinity]") }
  end

  def test_json_nesting_and_literals
    assert_equal({ "a" => [{ "b" => "1.5" }, "7", true, nil, "s"] },
                 Lattice::SchemaText.load_json(%({"a": [{"b": 1.5}, 7, true, null, "s"]})))
  end

  def weight_errors(weights)
    Lattice::Parser.parse_model_data(
      { "parameters" => { "a" => { "values" => %w[x y], "weights" => weights } }, "strength" => 1 }
    )
    nil
  rescue Lattice::ValidationError => e
    e.errors
  end

  def test_weight_text
    assert_nil weight_errors(["0.7", "3"])
    assert_nil weight_errors(["+1.5e-1", "007"])
    assert_nil weight_errors([0.5, 2])
    numeric = ["`weights` for parameter `a` must be numeric."]
    [["0x10", "1"], ["1_0", "1"], [".5", "1"], ["1.", "1"], ["inf", "1"], ["1e400", "1"], [true, "1"], [nil, "1"],
     [Float::INFINITY, 1], [Float::NAN, 1]].each do |weights|
      assert_equal numeric, weight_errors(weights), weights.inspect
    end
    assert_equal ["`weights` for parameter `a` must be greater than zero."], weight_errors(["0", "1"])
    assert_equal ["`weights` for parameter `a` must be greater than zero."], weight_errors(["-1", "1"])
  end

  def strength_result(strength)
    Lattice::Parser.parse_model_data({ "parameters" => { "a" => %w[x y], "b" => %w[x y], "c" => %w[x y] }, "strength" => strength }).strength
  rescue Lattice::ValidationError => e
    e.errors
  end

  def test_strength_text
    assert_equal 3, strength_result("3")
    assert_equal 2, strength_result("+2")
    assert_equal 1, strength_result("01")
    assert_equal 2, strength_result(2)
    assert_equal 2, strength_result(2.9)
    assert_equal 2, strength_result(nil)
    ["2.0", "0x2", "1_0", "two", true, Float::INFINITY, [2]].each do |strength|
      assert_equal ["`strength` must be an integer."], strength_result(strength), strength.inspect
    end
  end
end
