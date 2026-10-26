# frozen_string_literal: true

require "json"
require "optparse"

# Load the full library API so `require "lattice/cli"` alone is enough.
require_relative "../lattice"
require_relative "agent"
require_relative "constraints"
require_relative "formatters"
require_relative "ipog"
require_relative "parser"

module Lattice
  # Command-line interface mirroring the Python `lattice` CLI: same
  # subcommands, flags, defaults, output, and exit codes.
  module CLI
    DEFAULT_AGENT_FORMAT = "text"
    SCHEMA_HELP =
      "Schema features: constraints include invalid_pair, higher_order, " \
      "forward_dep, bidirectional, conditional, and forced; parameters may use " \
      "weights. Run `lattice agent instructions` for the full schema workflow."

    extend self

    def main(argv = ARGV)
      command = argv.first
      case command
      when "generate" then run_generate(argv.drop(1))
      when "validate" then run_validate(argv.drop(1))
      when "agent" then run_agent(argv.drop(1))
      when "--help", "-h", nil
        print_usage(command.nil? ? $stderr : $stdout)
        command.nil? ? 2 : 0
      else
        warn "lattice: unknown command `#{command}`"
        print_usage($stderr)
        2
      end
    rescue OptionParser::ParseError => e
      warn "lattice: #{e.message}"
      2
    end

    def print_usage(io)
      io.puts <<~USAGE
        usage: lattice {generate,validate,agent} ...

        commands:
          generate   Generate deterministic scenarios from a schema.
          validate   Validate a schema without generating scenarios.
          agent      Install and describe coding-agent integrations.

        #{SCHEMA_HELP}
      USAGE
    end

    def run_generate(argv)
      options = {
        format: "json",
        seed: 42,
        pool_size: 50,
        progress: false,
        progress_every: 10
      }
      parser = OptionParser.new do |opts|
        opts.on("--strength STRENGTH", Integer)
        opts.on("--format FORMAT", %w[table json csv summary yaml])
        opts.on("--seed SEED", Integer)
        opts.on("--pool-size SIZE", Integer) { |value| options[:pool_size] = value }
        opts.on("--max-rows ROWS", Integer) { |value| options[:max_rows] = value }
        opts.on("--stop-after-coverage PCT", Float) { |value| options[:stop_after_coverage] = value }
        opts.on("--progress")
        opts.on("--progress-every N", Integer) { |value| options[:progress_every] = value }
      end
      positional = parser.parse(argv, into: options)
      model_path = positional.first

      model = load_and_check_model(model_path, options)
      return model if model.is_a?(Integer)

      begin
        progress_callback = options[:progress] ? build_progress_callback(options[:progress_every]) : nil
        result = IPOG.generate_covering_array(
          model,
          strength: model.strength,
          seed: options[:seed],
          pool_size: options[:pool_size],
          progress: progress_callback,
          max_rows: options[:max_rows],
          stop_after_coverage: options[:stop_after_coverage]
        )
      rescue ArgumentError => e
        return emit_error(options, "generation_error", [e.message], exit_code: 1)
      end

      puts Formatters.render_output(model, result, output_format: options[:format], seed: options[:seed])
      0
    end

    def run_validate(argv)
      options = { format: "json" }
      parser = OptionParser.new do |opts|
        opts.on("--strength STRENGTH", Integer)
        opts.on("--format FORMAT", %w[json text])
      end
      positional = parser.parse(argv, into: options)
      model_path = positional.first

      model = load_and_check_model(model_path, options)
      return model if model.is_a?(Integer)

      print_validation_success(options, model)
      0
    end

    def load_and_check_model(model_path, options)
      model = Parser.load_model(model_path, strength_override: options[:strength])
      engine = ConstraintEngine.new(model)
      raise ValidationError, ["Model has no valid complete assignments."] unless engine.can_complete?({})

      model
    rescue ValidationError => e
      emit_error(options, "validation_error", e.errors, exit_code: 1)
    rescue ConstraintError => e
      emit_error(options, "constraint_error", [e.message], exit_code: 1)
    rescue ModelIOError => e
      emit_error(options, "io_error", [e.message], exit_code: 2)
    end

    def build_progress_callback(every)
      raise ArgumentError, "--progress-every must be at least 1" if every < 1

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      lambda do |progress|
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        case progress.event
        when "enumerating"
          eta = format_eta(elapsed, progress.covered, progress.total)
          $stderr.puts(
            "lattice progress: enumerating interactions " \
            "checked=#{progress.covered}/#{progress.total} " \
            "progress=#{format('%.1f', progress.cumulative_pct)}% " \
            "elapsed=#{format_seconds(elapsed)} " \
            "eta=#{eta}"
          )
        when "enumerated"
          $stderr.puts(
            "lattice progress: enumerated #{progress.total} valid interactions; starting generation"
          )
        else
          return if progress.event == "scenario" && (progress.scenario % every) != 0 && progress.uncovered != 0

          eta = format_eta(elapsed, progress.covered, progress.total)
          label = progress.event == "stopped" ? "stopped " : ""
          $stderr.puts(
            "lattice progress: #{label}scenario=#{progress.scenario} " \
            "covered=#{progress.covered}/#{progress.total} " \
            "coverage=#{format('%.1f', progress.cumulative_pct)}% " \
            "uncovered=#{progress.uncovered} " \
            "elapsed=#{format_seconds(elapsed)} " \
            "eta=#{eta}"
          )
        end
      end
    end

    def format_eta(elapsed, covered, total)
      return "unknown" if total <= 0 || covered <= 0
      return "0s" if covered >= total

      format_seconds(elapsed * ((total - covered).to_f / covered))
    end

    def format_seconds(seconds)
      seconds = [0, seconds.round].max
      minutes, sec = seconds.divmod(60)
      hours, minutes = minutes.divmod(60)
      return format("%dh%02dm%02ds", hours, minutes, sec) if hours.positive?
      return format("%dm%02ds", minutes, sec) if minutes.positive?

      "#{sec}s"
    end

    def emit_error(options, code, errors, exit_code:)
      if options[:format] == "json"
        puts JSON.pretty_generate({ "status" => "error", "code" => code, "errors" => errors }, ascii_only: true)
      else
        errors.each { |error| warn error }
      end
      exit_code
    end

    def print_validation_success(options, model)
      if options[:format] == "json"
        puts JSON.pretty_generate(
          {
            "status" => "ok",
            "valid" => true,
            "schema" => {
              "name" => model.model_name,
              "parameter_count" => model.parameters.length,
              "constraint_count" => model.constraints.length,
              "strength" => model.strength
            }
          },
          ascii_only: true
        )
        return
      end

      puts [
        "Schema is valid.",
        "name: #{model.model_name}",
        "parameters: #{model.parameters.length}",
        "constraints: #{model.constraints.length}",
        "strength: #{model.strength}"
      ].join("\n")
    end

    def run_agent(argv)
      command = argv.first
      rest = argv.drop(1)
      case command
      when "bootstrap" then run_agent_bootstrap(rest)
      when "install-codex-skill" then run_agent_install(rest, :codex)
      when "install-skill" then run_agent_install_generic(rest)
      when "install-claude-skill" then run_agent_install_claude(rest)
      when "memory" then run_agent_memory(rest)
      when "instructions" then run_agent_instructions(rest)
      when "doctor" then run_agent_doctor(rest)
      else
        warn "Unknown agent command `#{command}`."
        2
      end
    end

    def run_agent_bootstrap(argv)
      options = { format: DEFAULT_AGENT_FORMAT }
      parser = OptionParser.new do |opts|
        opts.on("--target TARGET")
        opts.on("--claude-target TARGET") { |value| options[:claude_target] = value }
        opts.on("--force-codex") { options[:force_codex] = true }
        opts.on("--skip-codex") { options[:skip_codex] = true }
        opts.on("--skip-claude") { options[:skip_claude] = true }
        opts.on("--force-claude") { options[:force_claude] = true }
        opts.on("--format FORMAT", %w[text json])
      end
      parser.parse(argv, into: options)

      codex_detected = Agent.codex_available?
      claude_available = Agent.claude_code_available?
      codex_skill_path = options[:target] ? File.expand_path(options[:target]) : Agent.default_codex_skill_path
      claude_skill_path = options[:claude_target] ? File.expand_path(options[:claude_target]) : Agent.default_claude_skill_path

      codex_setup, codex_skipped_reason = maybe_install_agent_skill(
        detected: codex_detected,
        force: options[:force_codex],
        skip: options[:skip_codex],
        skip_flag: "--skip-codex",
        unavailable_reason: "Codex was not detected"
      ) { Agent.install_codex_skill(options[:target]) }
      claude_setup, claude_skipped_reason = maybe_install_agent_skill(
        detected: claude_available,
        force: options[:force_claude],
        skip: options[:skip_claude],
        skip_flag: "--skip-claude",
        unavailable_reason: "Claude Code was not detected"
      ) { Agent.install_claude_skill(options[:claude_target], force: options[:force_claude]) }

      if options[:format] == "json"
        payload = {
          "status" => "ok",
          "codex" => agent_surface_payload(
            detected: codex_detected,
            setup: codex_setup,
            skill_path: codex_skill_path,
            skipped_reason: codex_skipped_reason
          ),
          "claude" => agent_surface_payload(
            detected: claude_available,
            setup: claude_setup,
            skill_path: claude_skill_path,
            skipped_reason: claude_skipped_reason
          ),
          "memory" => Agent::MEMORY_SNIPPET,
          "default_prompt" => Agent::DEFAULT_PROMPT,
          "instructions_command" => "lattice agent instructions",
          "generic_skill_command" => "lattice agent install-skill <target>"
        }
        puts JSON.pretty_generate(payload, ascii_only: true)
        return 0
      end

      print_agent_install_status("Codex", codex_setup, codex_skipped_reason)
      print_agent_install_status("Claude Code", claude_setup, claude_skipped_reason)
      puts ""
      puts "Agent memory:"
      puts Agent::MEMORY_SNIPPET
      puts ""
      puts "Default prompt:"
      puts Agent::DEFAULT_PROMPT
      puts ""
      puts "Any other harness:"
      puts "Run `lattice agent instructions`, or `lattice agent install-skill <target>` if the harness accepts a SKILL.md directory."
      0
    end

    def run_agent_install(argv, _surface)
      options = { format: DEFAULT_AGENT_FORMAT }
      parser = OptionParser.new do |opts|
        opts.on("--target TARGET")
        opts.on("--format FORMAT", %w[text json])
      end
      parser.parse(argv, into: options)
      setup = Agent.install_codex_skill(options[:target])
      emit_agent_setup(setup, "Codex", options[:format])
    end

    def run_agent_install_generic(argv)
      options = { format: DEFAULT_AGENT_FORMAT }
      parser = OptionParser.new do |opts|
        opts.on("--format FORMAT", %w[text json])
      end
      positional = parser.parse(argv, into: options)
      target = positional.first
      if target.nil?
        warn "lattice: `agent install-skill` requires a target directory."
        return 2
      end
      setup = Agent.install_generic_skill(target)
      emit_agent_setup(setup, "generic", options[:format])
    end

    def run_agent_install_claude(argv)
      options = { format: DEFAULT_AGENT_FORMAT }
      parser = OptionParser.new do |opts|
        opts.on("--target TARGET")
        opts.on("--force")
        opts.on("--format FORMAT", %w[text json])
      end
      parser.parse(argv, into: options)

      begin
        setup = Agent.install_claude_skill(options[:target], force: options[:force] || false)
      rescue RuntimeError => e
        if options[:format] == "json"
          puts JSON.pretty_generate({ "status" => "unavailable", "error" => e.message }, ascii_only: true)
        else
          warn e.message
        end
        return 1
      end

      emit_agent_setup(setup, "Claude Code", options[:format], extra: { "available" => Agent.claude_code_available? })
    end

    def run_agent_memory(argv)
      options = { format: DEFAULT_AGENT_FORMAT }
      OptionParser.new { |opts| opts.on("--format FORMAT", %w[text json]) }.parse(argv, into: options)
      if options[:format] == "json"
        puts JSON.pretty_generate({ "memory" => Agent::MEMORY_SNIPPET }, ascii_only: true)
      else
        puts Agent::MEMORY_SNIPPET
      end
      0
    end

    def run_agent_instructions(argv)
      options = { format: DEFAULT_AGENT_FORMAT }
      OptionParser.new { |opts| opts.on("--format FORMAT", %w[text json]) }.parse(argv, into: options)
      if options[:format] == "json"
        puts JSON.pretty_generate(
          {
            "instructions" => Agent::GENERIC_AGENT_INSTRUCTIONS,
            "memory" => Agent::MEMORY_SNIPPET,
            "default_prompt" => Agent::DEFAULT_PROMPT
          },
          ascii_only: true
        )
      else
        puts Agent::GENERIC_AGENT_INSTRUCTIONS
      end
      0
    end

    def run_agent_doctor(argv)
      options = { format: DEFAULT_AGENT_FORMAT }
      parser = OptionParser.new do |opts|
        opts.on("--target TARGET")
        opts.on("--claude-target TARGET") { |value| options[:claude_target] = value }
        opts.on("--format FORMAT", %w[text json])
      end
      parser.parse(argv, into: options)

      codex_path = options[:target] || Agent.default_codex_skill_path
      claude_path = options[:claude_target] || Agent.default_claude_skill_path
      codex_detected = Agent.codex_available?
      codex_installed = Agent.codex_skill_installed?(options[:target])
      claude_available = Agent.claude_code_available?
      claude_installed = Agent.claude_skill_installed?(options[:claude_target])
      known_harness_detected = codex_detected || claude_available
      ok = (!codex_detected || codex_installed) && (!claude_available || claude_installed)

      if options[:format] == "json"
        puts JSON.pretty_generate(
          {
            "status" => ok ? "ok" : "missing",
            "generic_instructions_available" => true,
            "known_harness_detected" => known_harness_detected,
            "codex_available" => codex_detected,
            "codex_skill_installed" => codex_installed,
            "codex_skill_path" => codex_path.to_s,
            "claude_code_available" => claude_available,
            "claude_skill_installed" => claude_installed,
            "claude_skill_path" => claude_path.to_s
          },
          ascii_only: true
        )
      else
        puts "Lattice agent setup"
        puts "cli: ok"
        puts "generic instructions: available (`lattice agent instructions`)"
        puts "codex: #{codex_detected ? 'available' : 'not detected'}"
        puts "codex skill: #{codex_installed ? 'installed' : 'missing'}"
        puts "codex path: #{codex_path}"
        puts "claude code: #{claude_available ? 'available' : 'not detected'}"
        puts "claude skill: #{claude_installed ? 'installed' : 'missing'}"
        puts "claude path: #{claude_path}"
      end
      ok ? 0 : 1
    end

    def maybe_install_agent_skill(detected:, force:, skip:, skip_flag:, unavailable_reason:)
      return [nil, "skipped by #{skip_flag}"] if skip
      return [yield, nil] if detected || force

      [nil, unavailable_reason]
    end

    def agent_surface_payload(detected:, setup:, skill_path:, skipped_reason:)
      {
        "available" => detected,
        "installed" => !setup.nil?,
        "skill_path" => (setup ? setup.skill_path : skill_path).to_s,
        "skipped_reason" => skipped_reason
      }
    end

    def emit_agent_setup(setup, label, output_format, extra: nil)
      if output_format == "json"
        puts JSON.pretty_generate({ "status" => "ok" }.merge(extra || {}).merge(setup.to_json_payload), ascii_only: true)
        return 0
      end

      puts "Installed `#{setup.skill_name}` #{label} skill at #{setup.skill_path}"
      0
    end

    def print_agent_install_status(label, setup, skipped_reason)
      if setup
        puts "Installed `#{setup.skill_name}` #{label} skill at #{setup.skill_path}"
      elsif skipped_reason
        puts "#{label} skill: not installed (#{skipped_reason})"
      end
    end
  end
end
