# frozen_string_literal: true

# Loads the Rust engine (Lattice::Engine). Precompiled gems carry one build per
# Ruby version (lib/lattice/3.4/...); a gem compiled on install has a single one
# next to this file.
begin
  require_relative "#{RUBY_VERSION[/\A\d+\.\d+/]}/lattice_native"
rescue LoadError
  require_relative "lattice_native"
end
