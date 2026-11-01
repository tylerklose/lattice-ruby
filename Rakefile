# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("latticerb.gemspec")

CROSS_PLATFORMS = %w[
  x86_64-linux aarch64-linux x86_64-linux-musl aarch64-linux-musl
  x86_64-darwin arm64-darwin x64-mingw-ucrt
].freeze

RbSys::ExtensionTask.new("lattice_native", GEMSPEC) do |ext|
  ext.lib_dir = "lib/lattice"
  ext.cross_compile = true
  ext.cross_platform = CROSS_PLATFORMS
end

Minitest::TestTask.create do |t|
  t.test_globs = ["test/**/*_test.rb"]
end

task test: :compile
task default: :test
