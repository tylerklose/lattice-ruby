# Lattice (Ruby)

Deterministic combinatorial coverage for constrained variant surfaces — roles, permissions, feature flags, modes, providers, optional fields, component props, config matrices — as a Ruby library and CLI.

Lattice takes a schema of parameters, values, and constraints and generates a minimal covering array: the smallest practical set of scenarios in which every valid pair (or triple, at strength 3) of values appears at least once. Constraints are honored during generation, so no scenario is ever invalid.

This is the Ruby implementation of [Lattice](https://github.com/tylerklose/lattice) ([lattice-cli on PyPI](https://pypi.org/project/lattice-cli/)). Same schema format, same algorithm, same seeds — **byte-identical output** for the same schema, seed, and pool size. That parity is enforced by the test suite, which runs both implementations and diffs their output. Use whichever runtime your project already has.

## Install

```ruby
# Gemfile
gem "latticerb"
```

or standalone:

```bash
gem install latticerb
```

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
run.to_table         # human-readable table (also: to_json_output, to_csv, to_summary)

Lattice.scenarios(file: "...")  # shortcut straight to the hashes
Lattice.validate!(schema)       # raises Lattice::ValidationError / Lattice::ConstraintError
```

Generation options: `strength:` (default 2 = pairwise), `seed:` (default 42), `pool_size:`, `max_rows:`, `stop_after_coverage:`.

## CLI usage

The gem installs a `lattice` executable mirroring the Python CLI:

```bash
cat schema.yaml | lattice validate
cat schema.yaml | lattice generate                 # JSON by default
lattice generate schema.yaml --format table
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

Constraint types: `invalid_pair`, `higher_order`, `forward_dep`, `bidirectional`, `conditional`, `forced`. Run `lattice agent instructions` for the full reference.

## Parity with the Python implementation

The generator seeds an MT19937 RNG that reproduces CPython's `random.Random` bit-for-bit, so both implementations walk the same candidate pools and pick the same rows. `test/python_parity_test.rb` shells out to the Python implementation (checkout via `LATTICE_PYTHON_SRC`, or an installed `lattice-cli`) and asserts byte-equal output across formats, seeds, strengths, and stopping rules; it skips when no Python implementation is available.

YAML is parsed with Psych here and PyYAML in Python — both YAML 1.1 (libyaml lineage), so common scalars including unquoted `yes`/`no`/`on`/`off` booleans resolve identically. Exotic YAML 1.1 corners (e.g. sexagesimal numbers) may differ between the two parsers; quote ambiguous scalars or use JSON if in doubt.

## Development

```bash
bundle install
bundle exec rake test        # unit, golden-parity, and live Python-parity suites
bundle exec mutant run       # mutation testing (see docs/mutation-testing.md)
```

Golden fixtures are authored by the reference Python implementation; regenerate
them with `ruby test/support/generate_goldens.rb` after intentional behavior
changes (requires the Python checkout, see the script header).

## License

Apache-2.0
