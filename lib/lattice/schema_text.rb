# frozen_string_literal: true

require "json"
require "psych"

module Lattice
  # Reads schema text (JSON or YAML) into plain Hashes, Arrays and Strings,
  # keeping every value as the text the user wrote. `1.10` stays "1.10",
  # `0x1F` stays "0x1F" and `2026-10-26T10:00:00Z` stays as typed, instead of
  # being converted to a number or time and printed back differently by Ruby
  # and Python. The only conversions:
  #
  # - unquoted yes/no/on/off/true/false (in the case forms below) become
  #   true/false, and an empty value, ~ or null becomes nil;
  # - JSON integers are written in plain decimal form.
  #
  # The Python implementation (lattice.schema_text) follows the same rules, and
  # test/fixtures/scalar_text.* pins the result for both.
  module SchemaText
    extend self

    class SyntaxError < StandardError; end

    TRUE_WORDS = %w[yes Yes YES true True TRUE on On ON].freeze
    FALSE_WORDS = %w[no No NO false False FALSE off Off OFF].freeze
    NULL_WORDS = ["", "~", "null", "Null", "NULL"].freeze

    YAML_TAG_PREFIX = "tag:yaml.org,2002:"
    STR_TAGS = ["!", "#{YAML_TAG_PREFIX}str"].freeze
    SCALAR_TAGS = %w[str int float bool null timestamp binary merge value].map { |name| "#{YAML_TAG_PREFIX}#{name}" }.freeze
    SEQUENCE_TAGS = [nil, "!", "#{YAML_TAG_PREFIX}seq"].freeze
    MAPPING_TAGS = [nil, "!", "#{YAML_TAG_PREFIX}map"].freeze

    # Hands JSON floats back as their source text.
    class RawNumber
      def self.new(text) = text
    end

    # Rejects a key written twice. json 2.x calls []= on a custom object_class;
    # json 3.x checks duplicates itself when allow_duplicate_key is false.
    class UniqueHash < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate key `#{key}`" if key?(key)

        super
      end
    end

    def load_json(text)
      json_strings(
        JSON.parse(text, decimal_class: RawNumber, object_class: UniqueHash, allow_duplicate_key: false)
      )
    end

    def load_yaml(text)
      documents = Psych.parse_stream(text).children
      raise SyntaxError, "expected a single YAML document, found #{documents.length}" if documents.length > 1
      return nil if documents.empty?

      yaml_value(documents.first.root, {})
    end

    private

    def json_strings(value)
      case value
      when Hash then value.to_h { |key, child| [key, json_strings(child)] }
      when Array then value.map { |child| json_strings(child) }
      when Integer then value.to_s
      else value
      end
    end

    # `anchors` maps each anchor to its value once built; an anchor still
    # being built (nil value) means an alias points back into itself.
    def yaml_value(node, anchors)
      return yaml_alias(node, anchors) if node.is_a?(Psych::Nodes::Alias)

      anchors[node.anchor] = nil if node.anchor
      value =
        case node
        when Psych::Nodes::Scalar then yaml_scalar(node)
        when Psych::Nodes::Sequence
          check_tag(node.tag, SEQUENCE_TAGS)
          node.children.map { |child| yaml_value(child, anchors) }
        when Psych::Nodes::Mapping then yaml_mapping(node, anchors)
        end
      anchors[node.anchor] = [value] if node.anchor
      value
    end

    def yaml_alias(node, anchors)
      built = anchors.fetch(node.anchor) { raise SyntaxError, "unknown alias `*#{node.anchor}`" }
      raise SyntaxError, "recursive alias" if built.nil?

      built.first
    end

    def yaml_scalar(node)
      check_tag(node.tag, [nil, "!"] + SCALAR_TAGS)
      return node.value unless node.style == Psych::Nodes::Scalar::PLAIN && !STR_TAGS.include?(node.tag)
      return true if TRUE_WORDS.include?(node.value)
      return false if FALSE_WORDS.include?(node.value)
      return nil if NULL_WORDS.include?(node.value)

      node.value
    end

    # Keys from `<<` merges come first, earlier sources winning; the
    # mapping's own keys then override them. A key written twice is an error.
    def yaml_mapping(node, anchors)
      check_tag(node.tag, MAPPING_TAGS)
      merged = {}
      own = {}
      seen_merge = false
      node.children.each_slice(2) do |key_node, value_node|
        key = yaml_value(key_node, anchors)
        raise SyntaxError, "mapping keys must be scalars" if key.is_a?(Enumerable)

        if merge_key?(key_node)
          raise SyntaxError, "duplicate key `<<`" if seen_merge

          seen_merge = true
          merge_sources(yaml_value(value_node, anchors)).each do |source|
            source.each { |merged_key, merged_value| merged[merged_key] = merged_value unless merged.key?(merged_key) }
          end
          next
        end

        raise SyntaxError, "duplicate key `#{Lattice.normalize_scalar(key)}`" if own.key?(key)

        own[key] = yaml_value(value_node, anchors)
      end
      merged.merge(own)
    end

    def merge_key?(key_node)
      key_node.is_a?(Psych::Nodes::Scalar) && key_node.style == Psych::Nodes::Scalar::PLAIN && key_node.value == "<<" &&
        [nil, "#{YAML_TAG_PREFIX}merge"].include?(key_node.tag)
    end

    def merge_sources(value)
      sources = [value].flatten(1)
      raise SyntaxError, "merge key `<<` needs a mapping or a list of mappings" unless sources.all?(Hash)

      sources
    end

    def check_tag(tag, allowed)
      raise SyntaxError, "unsupported YAML tag `#{tag}`" unless allowed.include?(tag)
    end
  end
end
