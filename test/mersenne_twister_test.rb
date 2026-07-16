# frozen_string_literal: true

require_relative "test_helper"

# Golden values generated with CPython 3:
#   random.Random(seed).getrandbits(64) / .random()
class MersenneTwisterTest < Minitest::Test
  def test_getrandbits_matches_cpython
    rng = Lattice::MersenneTwister.new(42)
    assert_equal 2_053_695_854_357_871_005, rng.getrandbits(64)
    assert_equal 13_679_192_365_072_849_617, rng.getrandbits(64)
    assert_equal 4_517_457_392_071_889_495, rng.getrandbits(64)
  end

  def test_random_matches_cpython
    rng = Lattice::MersenneTwister.new(42)
    assert_equal 0.6394267984578837, rng.random
    assert_equal 0.025010755222666936, rng.random
    assert_equal 0.27502931836911926, rng.random
  end

  def test_multiword_seed_matches_cpython
    rng = Lattice::MersenneTwister.new(12_345_678_901_234_567_890)
    assert_equal 0.5120180983871961, rng.random
    assert_equal 0.9318805526703359, rng.random
  end

  def test_zero_seed_matches_cpython
    assert_equal 0.8444218515250481, Lattice::MersenneTwister.new(0).random
  end
end
