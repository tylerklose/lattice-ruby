# Lattice (Ruby)

Deterministic combinatorial coverage for constrained variant surfaces — roles, permissions, feature flags, modes, providers, optional fields, component props, config matrices — as a Ruby library and CLI.

Lattice takes a schema of parameters, values, and constraints and generates a minimal covering array: the smallest practical set of scenarios in which every valid pair (or triple, at strength 3) of values appears at least once. Constraints are honored during generation, so no scenario is ever invalid.

This is the Ruby package of [Lattice](https://github.com/tylerklose/lattice) ([lattice-cli on PyPI](https://pypi.org/project/lattice-cli/)). Both packages generate scenarios with the same Rust engine, so they give **byte-identical output** for the same schema, seed and pool size. The test suite checks that by running both and comparing their output. Use whichever runtime your project already has.

## Install

```ruby
# Gemfile
gem "latticerb"
```

or standalone:

```bash
gem install latticerb
```

The gem ships precompiled for macOS (Apple Silicon and Intel), Linux (x86-64 and ARM64, glibc and musl) and Windows (x86-64). On other platforms it compiles the engine on install, which needs a Rust toolchain. JRuby isn't supported, because it can't load native extensions. If your Gemfile.lock was created on a Mac and you deploy to Linux, add the platform once: `bundle lock --add-platform x86_64-linux`.

## Library usage

The primary API is designed for test suites:

```ruby
require "lattice"

run = Lattice.generate(file: "spec/fixtures/checkout.yaml")

run.scenarios.each do |scenario|
  # { "payment_method" => "credit_card", "region" => "US", "card_type" => "visa", ... }
  it "checks out with #{scenario.values.join(', ')}" do
    # drive the flow with scenario values
  end
end
```

Schemas can also be inline Hashes or YAML/JSON strings:

```ruby
run = Lattice.generate(
  "parameters" => {
    "role" => %w[admin member guest],
    "plan" => %w[free pro enterprise],
    "beta_flag" => %w[on off]
  },
  "constraints" => [
    { "type" => "invalid_pair",
      "if" => { "parameter" => "role", "value" => "guest" },
      "then_not" => { "parameter" => "plan", "value" => "enterprise" } }
  ]
)

run.scenarios        # array of { name => value } hashes
run.coverage_curve   # cumulative coverage per scenario
run.to_table         # human-readable table (also: to_json_output, to_yaml_output, to_csv, to_summary)

Lattice.scenarios(file: "...")  # shortcut straight to the hashes
Lattice.validate!(schema)       # raises Lattice::ValidationError / Lattice::ConstraintError
```

Generation options: `strength:` (default 2 = pairwise), `seed:` (default 42), `pool_size:` (candidate rows per step, default 16), `max_rows:`, `stop_after_coverage:`.

## CLI usage

The gem installs a `lattice` executable mirroring the Python CLI:

```bash
cat schema.yaml | lattice validate
cat schema.yaml | lattice generate                 # JSON by default
lattice generate schema.yaml --format table
lattice generate schema.yaml --format yaml         # same content as JSON, for hand-edited files
lattice generate schema.yaml --strength 3 --seed 7
lattice agent instructions                          # coding-agent integration guidance
```

## Schema format

```yaml
model_name: checkout
strength: 2
parameters:
  payment_method: [credit_card, paypal, apple_pay]
  region: [US, UK, DE]
  browser:
    values: [chrome, safari, firefox]
    weights: [0.6, 0.3, 0.1]
constraints:
  - type: invalid_pair
    if: { parameter: payment_method, value: apple_pay }
    then_not: { parameter: browser, value: firefox }
  - type: conditional
    parameter: card_type
    values: [visa, mastercard]
    parent: payment_method
    applies_when: [credit_card]
```

Constraint types: `invalid_pair`, `higher_order`, `forward_dep`, `bidirectional`, `conditional`, `forced`. Every constraint needs a `type` key. Run `lattice agent instructions` for an example of each type.

### Values keep their text

Every value in a schema (the model name, parameter names and values, and constraint references) is used exactly as written. In YAML, unquoted `1.10`, `0x1F`, `.inf` or `2026-10-26T10:00:00Z` stay as typed rather than being turned into numbers or dates. The exceptions:

- Unquoted `yes`, `no`, `on`, `off`, `true` and `false` (lowercase, Capitalized or UPPERCASE) become `true` / `false`, and an empty value, `~` or `null` becomes `null`. Quote them (`"yes"`) to keep the word.
- JSON integers are written in plain decimal form (`-0` becomes `0`).

`strength` must be a whole number, and `weights` decimal numbers such as `0.7` or `1e-3`. Anchors, aliases and `<<` merge keys work; a key written twice, more than one YAML document, or a tag other than YAML's standard ones is an error.

Changed in 0.3.0: earlier versions converted unquoted numbers and dates, so `0x1F` became `31`, `1.10` became `1.1`, and some values (`.inf`, timestamps) came out differently in the Ruby and Python implementations.

## Performance

Generation runs in a Rust engine (the `lattice-engine` crate), in two phases:

1. **Build.** Rows are added greedily. Each row is the best of several candidates (`pool_size:`, default 16), and each candidate picks, value by value, whatever covers the most combinations still uncovered.
2. **Shrink.** A row is removed and the gaps are repaired with tabu search, which changes values in the remaining rows without breaking any constraint or forced combination. This repeats while repairs succeed within a fixed step budget.

The budget is a number of steps, not a time limit, so the same schema and seed give the same rows on every machine. The rows come out ordered so each adds the most new coverage, which is why `max_rows:` and `stop_after_coverage:` cut the set short with as much coverage as possible.

Scenario counts against [PICT](https://github.com/microsoft/pict) 3.7, with default settings for both:

| Model | PICT | Lattice 0.4 | Lattice 0.3 |
|---|---|---|---|
| 13 parameters × 3 values | 20 | **15** (best known) | 22 |
| 100 × 2 | 16 | **10** (optimal) | over 60 s |
| 61 mixed (4^15 3^17 2^29) | 40 | **30** | over 60 s |
| 12 × 6 | 70 | **60** | 88 (32 s) |
| 30 × 5 | 66 | **55** | over 60 s |
| 20 × 10 | 218 | **192** | over 60 s |
| Strength 3, 10 × 4 | 158 | **140** | 176 (27 s) |

Each Lattice 0.4 run above takes 0.04–1.2 s on an Apple M-series laptop. PICT is faster (about 0.02 s) because it stops after the build phase.

Changed in 0.4.0: rows differ from 0.3.x for the same seed, and every example needs the same number of scenarios or fewer. `pool_size:` now sets the candidates per row; its default went from 50 to 16.

## Parity with the Python implementation

Both packages parse schemas in their own language and hand the engine the same compiled constraints (`ConstraintEngine#engine_constraints` here, `lattice.ipog` in Python), so the engine gets identical input. `test/python_parity_test.rb` shells out to the Python implementation (checkout via `LATTICE_PYTHON_SRC`, or an installed `lattice-cli`) and asserts byte-equal output across formats, seeds, strengths and stopping rules; it skips when no Python implementation is available.

Schemas are read with Psych here and PyYAML in Python, but both implementations build values from the parsed text with the same rules (see "Values keep their text"), so a schema means the same thing in either. `test/fixtures/scalar_text.*` pins those rules for both.

## Development

Building the extension needs a Rust toolchain (`rustup`), and, until `lattice-engine` is on crates.io, a checkout of it next to this repo (`../lattice-engine`).

```bash
bundle install
bundle exec rake compile     # builds lib/lattice/lattice_native
bundle exec rake test        # unit, golden-parity, and live Python-parity suites (compiles first)
bundle exec mutant run       # mutation testing (see docs/mutation-testing.md)
```

Golden fixtures are authored by the reference Python implementation; regenerate
them with `ruby test/support/generate_goldens.rb` after intentional behavior
changes (requires the Python checkout, see the script header).

## License

Apache-2.0
