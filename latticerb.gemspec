# frozen_string_literal: true

require_relative "lib/lattice/version"

Gem::Specification.new do |spec|
  spec.name = "latticerb"
  spec.version = Lattice::VERSION
  spec.authors = ["Tyler Klose"]
  spec.email = ["tylerklose@gmail.com"]

  spec.summary = "Deterministic combinatorial coverage for agent workflows and constrained variant surfaces."
  spec.description =
    "Lattice generates deterministic pairwise/t-way covering arrays from a constrained schema of " \
    "parameters and values. Use it as a library in test suites (RSpec, Minitest, Rails fixtures) " \
    "or via the bundled `lattice` CLI. Output is row-for-row identical to the Python " \
    "lattice-cli package for the same schema and seed."
  spec.homepage = "https://github.com/tylerklose/lattice-ruby"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "exe/*", "LICENSE", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["lattice"]
  spec.require_paths = ["lib"]

  spec.add_dependency "csv", ">= 3.0"
end
