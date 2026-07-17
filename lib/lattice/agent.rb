# frozen_string_literal: true

require "fileutils"

module Lattice
  module Agent
    SKILL_NAME = "lattice-workflow"

    MEMORY_SNIPPET =
      "Reach for Lattice when planning, testing, or reviewing a finite constrained surface " \
      "with interacting states such as roles, permissions, feature flags, modes, providers, " \
      "optional fields, component props, rendering branches, template variants, config " \
      "matrices, lifecycle states, or cross-product edge cases. Extract a schema with " \
      "parameters, values, and true constraints; run `lattice validate`; then run " \
      "`lattice generate`; use the generated rows as the source of truth for plan review, " \
      "rendered variants, fixtures, or missing tests instead of hand-enumerating pairwise " \
      "combinations."

    DEFAULT_PROMPT =
      "Use $lattice-workflow. Inspect this feature, test surface, component variant space, " \
      "template, or config matrix; extract a Lattice schema; validate it; generate pairwise " \
      "rows; and use the rows to strengthen the plan, tests, fixtures, or visual review."

    GENERIC_AGENT_INSTRUCTIONS = <<~INSTRUCTIONS
      # Lattice Agent Instructions

      Lattice is harness-agnostic. Use these instructions in OpenClaw, Hermes, Codex, xAI-backed agents, Claude Code, or any agent that can run shell commands.

      Memory:
      #{MEMORY_SNIPPET}

      Default prompt:
      #{DEFAULT_PROMPT}

      Workflow:
      1. Check whether `lattice --help` works.
      2. Extract one coherent schema with parameters, values, and true constraints.
      3. Encode nonsensical or impossible combinations as constraints. Do not strip constraints and mark invalid rows after generation. Lattice supports exclusion-style constraints such as `invalid_pair` and `higher_order`, not only `conditional` parameters.
      4. Run `lattice validate` before generation.
      5. Run `lattice generate` and treat the generated rows as the source of truth.
      6. Map rows to the active evaluator: plan review, tests, fixtures, rendered variants, screenshots, visual diffs, sandbox calls, or another harness-specific action.

      Prefer JSON or YAML on stdin:

      ```bash
      cat schema.json | lattice validate
      cat schema.json | lattice generate
      ```
    INSTRUCTIONS

    AgentSetup = Data.define(:surface, :skill_name, :skill_path, :memory, :default_prompt) do
      def to_json_payload
        {
          "surface" => surface,
          "skill_name" => skill_name,
          "skill_path" => skill_path.to_s,
          "memory" => memory,
          "default_prompt" => default_prompt
        }
      end
    end

    extend self

    def default_codex_skill_path
      codex_home = ENV.fetch("CODEX_HOME", nil)
      base = codex_home && !codex_home.empty? ? File.expand_path(codex_home) : File.join(Dir.home, ".codex")
      File.join(base, "skills", SKILL_NAME)
    end

    def default_claude_skill_path
      File.join(Dir.home, ".claude", "skills", SKILL_NAME)
    end

    def codex_available?
      !which("codex").nil? ||
        File.exist?(File.join(Dir.home, ".codex")) ||
        !ENV.fetch("CODEX_HOME", "").empty?
    end

    def claude_code_available?
      !which("claude").nil? || File.exist?(File.join(Dir.home, ".claude"))
    end

    def install_codex_skill(target = nil)
      destination = target ? File.expand_path(target) : default_codex_skill_path
      copy_bundled_skill("codex", destination)
      AgentSetup.new(
        surface: "codex",
        skill_name: SKILL_NAME,
        skill_path: destination,
        memory: MEMORY_SNIPPET,
        default_prompt: DEFAULT_PROMPT
      )
    end

    def install_generic_skill(target)
      destination = File.expand_path(target)
      copy_bundled_skill("generic", destination)
      AgentSetup.new(
        surface: "generic",
        skill_name: SKILL_NAME,
        skill_path: destination,
        memory: MEMORY_SNIPPET,
        default_prompt: DEFAULT_PROMPT
      )
    end

    def install_claude_skill(target = nil, force: false)
      if !force && !claude_code_available?
        raise "Claude Code was not detected. Re-run with --force to install anyway."
      end

      destination = target ? File.expand_path(target) : default_claude_skill_path
      copy_bundled_skill("claude", destination)
      AgentSetup.new(
        surface: "claude-code",
        skill_name: SKILL_NAME,
        skill_path: destination,
        memory: MEMORY_SNIPPET,
        default_prompt: DEFAULT_PROMPT
      )
    end

    def codex_skill_installed?(target = nil)
      destination = target ? File.expand_path(target) : default_codex_skill_path
      File.file?(File.join(destination, "SKILL.md"))
    end

    def claude_skill_installed?(target = nil)
      destination = target ? File.expand_path(target) : default_claude_skill_path
      File.file?(File.join(destination, "SKILL.md"))
    end

    def copy_bundled_skill(resource_name, destination)
      source = File.join(__dir__, "resources", resource_name, SKILL_NAME)
      unless File.directory?(source)
        raise "Bundled #{resource_name} skill `#{SKILL_NAME}` was not found."
      end

      FileUtils.mkdir_p(destination)
      FileUtils.cp_r(File.join(source, "."), destination)
    end

    def which(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        candidate = File.join(directory, command)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end
  end
end
