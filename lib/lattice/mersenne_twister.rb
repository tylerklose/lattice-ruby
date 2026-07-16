# frozen_string_literal: true

module Lattice
  # MT19937 matching CPython's `random.Random` bit-for-bit — same integer
  # seeding (init_by_array over 32-bit words), same 53-bit `random`, same
  # little-endian word order for `getrandbits` — so a given seed produces
  # identical covering arrays here and in the Python implementation.
  class MersenneTwister
    N = 624
    M = 397
    MATRIX_A = 0x9908b0df
    UPPER_MASK = 0x80000000
    LOWER_MASK = 0x7fffffff
    MASK32 = 0xffffffff

    def initialize(seed)
      seed = seed.abs
      key = []
      while seed.positive?
        key << (seed & MASK32)
        seed >>= 32
      end
      key << 0 if key.empty?
      init_by_array(key)
    end

    def random
      a = genrand_uint32 >> 5
      b = genrand_uint32 >> 6
      (a * 67_108_864.0 + b) * (1.0 / 9_007_199_254_740_992.0)
    end

    def getrandbits(bits)
      result = 0
      shift = 0
      while bits.positive?
        word = genrand_uint32
        word >>= (32 - bits) if bits < 32
        result |= word << shift
        shift += 32
        bits -= 32
      end
      result
    end

    private

    def init_genrand(seed)
      @mt = Array.new(N)
      @mt[0] = seed & MASK32
      (1...N).each do |i|
        @mt[i] = (1_812_433_253 * (@mt[i - 1] ^ (@mt[i - 1] >> 30)) + i) & MASK32
      end
      @mti = N
    end

    def init_by_array(key)
      init_genrand(19_650_218)
      i = 1
      j = 0
      count = [N, key.length].max
      while count.positive?
        @mt[i] = ((@mt[i] ^ ((@mt[i - 1] ^ (@mt[i - 1] >> 30)) * 1_664_525)) + key[j] + j) & MASK32
        i += 1
        j += 1
        if i >= N
          @mt[0] = @mt[N - 1]
          i = 1
        end
        j = 0 if j >= key.length
        count -= 1
      end
      count = N - 1
      while count.positive?
        @mt[i] = ((@mt[i] ^ ((@mt[i - 1] ^ (@mt[i - 1] >> 30)) * 1_566_083_941)) - i) & MASK32
        i += 1
        if i >= N
          @mt[0] = @mt[N - 1]
          i = 1
        end
        count -= 1
      end
      @mt[0] = 0x80000000
    end

    def genrand_uint32
      if @mti >= N
        (0...N).each do |kk|
          y = (@mt[kk] & UPPER_MASK) | (@mt[(kk + 1) % N] & LOWER_MASK)
          @mt[kk] = @mt[(kk + M) % N] ^ (y >> 1) ^ (y.odd? ? MATRIX_A : 0)
        end
        @mti = 0
      end
      y = @mt[@mti]
      @mti += 1
      y ^= (y >> 11)
      y = (y ^ ((y << 7) & 0x9d2c5680)) & MASK32
      y = (y ^ ((y << 15) & 0xefc60000)) & MASK32
      y ^ (y >> 18)
    end
  end
end
