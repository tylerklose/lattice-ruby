# frozen_string_literal: true

require_relative "test_helper"
require "lattice/agent"

# Every schema shown to users or agents must be one Lattice accepts. Checks
# each ```yaml or ```json block that defines `parameters` in the shipped skill
# files, the README and `lattice agent instructions`.
class DocsExamplesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FENCED_BLOCK = /^```(yaml|json)\n(.*?)^```/m

  def self.schema_blocks(name, text)
    text.scan(FENCED_BLOCK).each_with_index.filter_map do |(language, body), index|
      ["#{name} block #{index + 1}", language, body] if body.include?("parameters")
    end
  end

  SOURCES = Dir[File.join(ROOT, "lib/lattice/resources/**/*.md")].sort.to_h do |path|
    [path.delete_prefix("#{ROOT}/"), File.read(path)]
  end.merge(
    "README.md" => File.read(File.join(ROOT, "README.md")),
    "lattice agent instructions" => Lattice::Agent::GENERIC_AGENT_INSTRUCTIONS
  ).freeze

  BLOCKS = SOURCES.flat_map { |name, text| schema_blocks(name, text) }.freeze

  def test_finds_a_schema_in_every_skill_readme_and_the_agent_instructions
    names = BLOCKS.map { |label, _language, _body| label.sub(/ block \d+\z/, "") }.uniq
    expected = SOURCES.keys.select { |name| name.end_with?("SKILL.md") } + ["README.md", "lattice agent instructions"]
    assert_empty expected - names, "no schema example found in these sources"
  end

  def test_agent_instructions_show_every_constraint_type
    Lattice::Parser::CONSTRAINT_FIELDS.each_key do |type|
      assert_includes Lattice::Agent::GENERIC_AGENT_INSTRUCTIONS, "- type: #{type}\n"
    end
  end

  BLOCKS.each do |label, language, body|
    define_method("test_valid_schema_#{label.gsub(/\W+/, '_')}") do
      data = language == "json" ? Lattice::SchemaText.load_json(body) : Lattice::SchemaText.load_yaml(body)
      model = Lattice::Parser.parse_model_data(data)
      assert Lattice::ConstraintEngine.new(model).can_complete?({}), "#{label} has no valid rows"
    rescue Lattice::ValidationError => e
      flunk "#{label} is not a valid schema: #{e.errors.join(' ')}"
    end
  end
end
