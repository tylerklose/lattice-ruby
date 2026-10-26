# frozen_string_literal: true

require "csv"
require "json"

require_relative "ipog"
require_relative "model"

module Lattice
  # Output rendering. Table, JSON, CSV, summary, and YAML formats are
  # byte-identical to the Python implementation's output for the same model
  # and result.
  module Formatters
    extend self

    def render_output(model, result, output_format:, seed:)
      case output_format
      when "table" then format_table(model, result)
      when "json" then format_json(model, result, seed:)
      when "csv" then format_csv(model, result)
      when "summary" then format_summary(model, result)
      when "yaml" then format_yaml(model, result, seed:)
      else
        raise ArgumentError, "Unknown format `#{output_format}`."
      end
    end

    def format_table(model, result)
      rows = named_rows(model, result)
      headers = ["#"] + model.parameter_names
      body = rows.each_with_index.map do |row, index|
        [(index + 1).to_s] + model.parameter_names.map { |name| row[name] }
      end
      widths = headers.each_index.map do |column|
        ([headers[column].length] + body.map { |record| record[column].length }).max
      end

      lines = [headline(model, result), ""]
      lines.concat(milestone_lines(result))
      lines << ""
      lines << headers.each_index.map do |column|
        column.zero? ? headers[column].rjust(widths[column]) : headers[column].ljust(widths[column])
      end.join(" | ")
      lines << widths.map { |width| "-" * width }.join("-|-")

      body.each do |record|
        lines << record.each_index.map do |column|
          column.zero? ? record[column].rjust(widths[column]) : record[column].ljust(widths[column])
        end.join(" | ")
      end
      lines.join("\n")
    end

    def format_summary(model, result)
      lines = [headline(model, result), ""]
      lines.concat(milestone_lines(result))
      lines.join("\n")
    end

    def format_json(model, result, seed:)
      last_point = result.coverage_curve.last
      payload = {
        "meta" => {
          "model_name" => model.model_name,
          "strength" => model.strength,
          "test_count" => result.rows.length,
          "exhaustive_count" => model.exhaustive_count,
          "reduction" => reduction_label(model.exhaustive_count, result.rows.length),
          "coverage" => last_point ? format("%.1f%%", last_point.cumulative_pct) : "0.0%",
          "seed" => seed
        },
        "coverage_curve" => result.coverage_curve.map do |point|
          { "scenario" => point.scenario, "cumulative_pct" => point.cumulative_pct }
        end,
        "scenarios" => named_rows(model, result).each_with_index.map do |row, index|
          {
            "id" => index + 1,
            "values" => model.parameter_names.to_h { |name| [name, row[name]] }
          }
        end
      }
      JSON.pretty_generate(payload, ascii_only: true)
    end

    # Same content as format_json, written by hand in one fixed style so Ruby
    # and Python emit identical bytes (Psych and PyYAML each quote and wrap
    # differently). Every string is double-quoted, so no value can be read
    # back as a boolean, null, number or date.
    def format_yaml(model, result, seed:)
      last_point = result.coverage_curve.last
      lines = [
        "meta:",
        "  model_name: #{yaml_string(model.model_name)}",
        "  strength: #{model.strength}",
        "  test_count: #{result.rows.length}",
        "  exhaustive_count: #{model.exhaustive_count}",
        "  reduction: #{yaml_string(reduction_label(model.exhaustive_count, result.rows.length))}",
        "  coverage: #{yaml_string(last_point ? format('%.1f%%', last_point.cumulative_pct) : '0.0%')}",
        "  seed: #{seed.nil? ? 'null' : seed}"
      ]

      if result.coverage_curve.empty?
        lines << "coverage_curve: []"
      else
        lines << "coverage_curve:"
        result.coverage_curve.each do |point|
          lines << "  - scenario: #{point.scenario}"
          lines << "    cumulative_pct: #{JSON.generate(point.cumulative_pct)}"
        end
      end

      rows = named_rows(model, result)
      if rows.empty?
        lines << "scenarios: []"
      else
        lines << "scenarios:"
        rows.each_with_index do |row, index|
          lines << "  - id: #{index + 1}"
          lines << "    values:"
          model.parameter_names.each do |name|
            lines << "      #{yaml_string(name)}: #{yaml_string(row[name])}"
          end
        end
      end
      lines.join("\n")
    end

    YAML_ESCAPES = {
      "\"" => "\\\"", "\\" => "\\\\", "\b" => "\\b", "\t" => "\\t", "\n" => "\\n", "\f" => "\\f", "\r" => "\\r"
    }.freeze

    # Characters escaped inside a double-quoted YAML string: the quote and
    # backslash, C0 controls, DEL, C1 controls (U+0085 would otherwise fold to
    # a space), the Unicode line and paragraph separators, the byte-order mark,
    # and the two noncharacters YAML cannot hold. Everything else is written as
    # UTF-8, so accented letters and emoji stay readable.
    YAML_ESCAPED_CHARS = /["\\\u0000-\u001f\u007f-\u009f\u2028\u2029\ufeff\ufffe\uffff]/

    def yaml_string(value)
      escaped = value.gsub(YAML_ESCAPED_CHARS) do |char|
        YAML_ESCAPES.fetch(char) { format("\\u%04x", char.ord) }
      end
      "\"#{escaped}\""
    end

    def format_csv(model, result)
      CSV.generate(row_sep: "\r\n") do |csv|
        csv << model.parameter_names
        named_rows(model, result).each do |row|
          csv << model.parameter_names.map { |name| row[name] }
        end
      end.strip
    end

    def headline(model, result)
      "Lattice — #{result.rows.length} scenarios (from #{thousands(model.exhaustive_count)} possible)"
    end

    def milestone_lines(result)
      [50.0, 75.0, 90.0, 100.0].filter_map do |threshold|
        point = result.coverage_curve.find { |candidate| candidate.cumulative_pct >= threshold }
        "  #{threshold.to_i}% coverage at scenario ##{point.scenario}" if point
      end
    end

    def named_rows(model, result)
      result.rows.map do |row|
        model.parameters.each_with_index.to_h do |parameter, index|
          [parameter.name, parameter.values[row[index]]]
        end
      end
    end

    def reduction_label(exhaustive_count, scenario_count)
      return "inf" if scenario_count.zero?

      reduction = exhaustive_count.to_f / scenario_count
      if (reduction - reduction.round).abs < 1e-9
        "#{reduction.round(half: :even)}x"
      else
        format("%.1fx", reduction)
      end
    end

    def thousands(count)
      count.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    end
  end
end
