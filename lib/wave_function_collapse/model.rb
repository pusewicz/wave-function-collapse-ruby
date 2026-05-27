# frozen_string_literal: true

module WaveFunctionCollapse
  # Wave Function Collapse — chunked-Fixnum wave + AC-4 compatible counter.
  #
  # Each cell's domain is split across `@chunk_count` parallel Fixnum arrays
  # (`@wave_chunks[ch][c]`), each chunk holding up to `WAVE_CHUNK_BITS` tiles.
  # Keeping every chunk a Fixnum lets the hot propagation loop AND a wave
  # chunk with a precomputed `@propagator_chunks[d][t][ch]` mask and iterate
  # the resulting set bits — no Bignum allocations on the inner path.
  # Supporter counts live in a flat byte buffer (`@compatible`); when a count
  # hits zero the tile is banned at that cell, which kicks off iterative
  # propagation through an explicit stack. Entropy is maintained incrementally
  # per cell.
  class Model
    DX = [0, 1, 0, -1].freeze
    DY = [1, 0, -1, 0].freeze
    OPP = [2, 3, 0, 1].freeze

    # Bits per wave chunk. MRI's Fixnum holds 62 unsigned bits before
    # promoting to Bignum, so 62 keeps every wave/propagator chunk in
    # tagged-integer land and every `&`/`^`/`& -m`/`bit_length` op cheap.
    WAVE_CHUNK_BITS = 62

    # Upper bound on consecutive contradiction restarts before
    # `observe_and_propagate` gives up. Solvable tilesets almost always
    # succeed in one or two attempts; inherently-broken inputs would
    # otherwise loop forever.
    MAX_RESTARTS = 100

    attr_reader :tiles, :width, :height, :max_entropy, :generation

    def initialize(tiles, width, height)
      @tiles = tiles
      @width = width.to_i
      @height = height.to_i
      @num_tiles = tiles.length
      @max_entropy = @num_tiles
      @cells_count = @width * @height
      @generation = 0
      @chunk_count = (@num_tiles + WAVE_CHUNK_BITS - 1) / WAVE_CHUNK_BITS

      build_propagator
      build_initial_state
      setup_wave_state

      # All long-lived precomputed data (propagator, neighbours, bit
      # tables, compatible template + fill sentinel, weights) is frozen
      # and lives for the model's lifetime. Compact once now so it
      # settles into old gen and doesn't fragment the heap as solves
      # churn young-gen objects. Skipped for tiny grids where compaction
      # cost outweighs the win.
      ::GC.compact if @cells_count >= 400
    end

    def complete?
      @uncollapsed_count == 0 && !@contradiction
    end

    def percent
      (@cells_count - @uncollapsed_count).to_f / @cells_count * 100
    end

    def entropy_at(x, y)
      @remaining[y * @width + x]
    end

    # Tileset asset id (Integer) at (x, y), or nil if uncollapsed. Lighter
    # than `tile_at` for hot draw paths that only need the asset id.
    def tile_id_at(x, y)
      t = @chosen_tile[y * @width + x]
      t < 0 ? nil : @tiles[t].tileid
    end

    def solve
      observe_and_propagate
      true
    end

    def iterate
      return false if complete?
      observe_and_propagate
      true
    end

    # Returns a 2-D array indexed [x][y] of tiles (nil for uncollapsed cells).
    # Called on demand by the renderer; not by iterate/solve.
    def grid
      generate_grid
    end

    def prepend_empty_row
      w = @width
      n = @cells_count
      shift_count = n - w

      # Don't carry a leftover flag from an earlier failed run into the
      # new pass — and reset the propagation stacks too, since they may
      # still hold entries from a contradiction that returned early.
      @contradiction = false
      @prop_cells.clear
      @prop_tiles.clear

      # Shift state down in place: drop bottom row (cells 0..w-1), fill
      # the new top row with default values. Copying low-to-high is safe
      # because each source index (i + w) is greater than its destination.
      ch = 0
      while ch < @chunk_count
        shift_uniform!(@wave_chunks[ch], shift_count, @full_chunk_masks[ch])
        ch += 1
      end
      shift_uniform!(@remaining, shift_count, @num_tiles)
      shift_uniform!(@sum_w, shift_count, @initial_sum_w)
      shift_uniform!(@sum_w_log_w, shift_count, @initial_sum_w_log_w)
      # When the tileset has a single tile every cell is born collapsed,
      # so the new row's chosen_tile must point at tile 0 rather than the
      # generic "uncollapsed" sentinel — mirroring the t_max==1 branch in
      # setup_wave_state. Without this, complete? returns true (because
      # remaining[c] == 1) while grid returns nil for the whole new row.
      shift_uniform!(@chosen_tile, shift_count, (@num_tiles == 1) ? 0 : -1)

      noise = @noise
      entropy_noise = @entropy_noise
      initial_entropy = @initial_entropy
      i = 0
      # Carry both the noise and the merged `entropy + noise` value down
      # so existing rows keep their evolved entropies, then mint fresh
      # noise (and corresponding initial entropy_noise) for the new top
      # rows.
      while i < shift_count
        noise[i] = noise[i + w]
        entropy_noise[i] = entropy_noise[i + w]
        i += 1
      end
      while i < n
        nz = ::Kernel.rand * 1e-6
        noise[i] = nz
        entropy_noise[i] = initial_entropy + nz
        i += 1
      end

      @uncollapsed_count = 0
      c = 0
      while c < n
        @uncollapsed_count += 1 if @remaining[c] > 1
        c += 1
      end

      rebuild_compatible_from_wave
      orphan_ban_pass
      propagate

      if @contradiction
        # The new row can't be reconciled with the row below it. The
        # wave is now half-mutated — if we returned anyway, the next
        # `iterate` would observe `@contradiction == true`, call
        # `setup_wave_state`, and silently wipe every streamed row.
        # Reset to a clean blank state and tell the caller the prepend
        # failed so it can decide what to do.
        setup_wave_state
        return false
      end
      @generation += 1
      true
    end

    # Returns a 2-D array indexed [x][y] of tiles, or nil for uncollapsed cells.
    def generate_grid
      result = ::Array.new(@width)
      x = 0
      while x < @width
        col = result[x] = ::Array.new(@height)
        y = 0
        while y < @height
          col[y] = tile_at(x, y)
          y += 1
        end
        x += 1
      end
      result
    end

    private

    # ---- one-time precomputation ------------------------------------------------

    def build_propagator
      tiles = @tiles
      t_max = @num_tiles
      chunk_count = @chunk_count

      # Canonical integer ID per unique edge signature (Array of 3 ints).
      edge_id = {}
      ups = ::Array.new(t_max)
      rights = ::Array.new(t_max)
      downs = ::Array.new(t_max)
      lefts = ::Array.new(t_max)
      t = 0
      while t < t_max
        tile = tiles[t]
        ups[t] = (edge_id[tile.up] ||= edge_id.size)
        rights[t] = (edge_id[tile.right] ||= edge_id.size)
        downs[t] = (edge_id[tile.down] ||= edge_id.size)
        lefts[t] = (edge_id[tile.left] ||= edge_id.size)
        t += 1
      end

      # Edge per (tile, direction). Index by direction id: 0=up,1=right,2=down,3=left.
      edges_per_dir = [ups, rights, downs, lefts]

      # propagator_chunks[d][a][ch] = Fixnum mask of tiles in chunk `ch`
      # such that match(a, d, b) — i.e. tile a's edge in dir d equals
      # tile b's edge in opposite(d). Also keep `propagator_counts[d][a]`
      # = popcount of all chunks (initial supporter count for an interior
      # cell). Bignum `propagator[d][a]` is built once for
      # `rebuild_compatible_from_wave` (cold path) only.
      propagator = ::Array.new(4) { ::Array.new(t_max, 0) }
      propagator_chunks = ::Array.new(4) { ::Array.new(t_max) { ::Array.new(chunk_count, 0) } }
      propagator_counts = ::Array.new(4) { ::Array.new(t_max, 0) }

      d = 0
      while d < 4
        opp_d = OPP[d]
        my_edges = edges_per_dir[d]
        opp_edges = edges_per_dir[opp_d]
        a = 0
        while a < t_max
          my_edge = my_edges[a]
          mask = 0
          count = 0
          chunks = propagator_chunks[d][a]
          b = 0
          while b < t_max
            if opp_edges[b] == my_edge
              mask |= (1 << b)
              ch = b / WAVE_CHUNK_BITS
              chunks[ch] |= (1 << (b - ch * WAVE_CHUNK_BITS))
              count += 1
            end
            b += 1
          end
          propagator[d][a] = mask
          propagator_counts[d][a] = count
          chunks.freeze
          a += 1
        end
        propagator[d].freeze
        propagator_chunks[d].each(&:freeze)
        propagator_chunks[d].freeze
        propagator_counts[d].freeze
        d += 1
      end

      @propagator = propagator.freeze
      @propagator_chunks = propagator_chunks.freeze
      @propagator_counts = propagator_counts.freeze

      # Supporter counts live in a byte buffer (`@compatible`), so any
      # propagator count above 255 would silently wrap modulo 256 at
      # build time and corrupt the AC-4 invariants — `complete?` can
      # even start returning true while the wave is actually contradicted.
      # Reject these tilesets up front rather than producing wrong output.
      d = 0
      while d < 4
        a = 0
        while a < t_max
          if propagator_counts[d][a] > 255
            ::Kernel.raise(
              ::WaveFunctionCollapse::Error,
              "tile #{a} has #{propagator_counts[d][a]} compatible " \
              "neighbours in direction #{d}; the byte-packed supporter " \
              "counter only fits 0..255"
            )
          end
          a += 1
        end
        d += 1
      end

      # Weights
      weights = ::Array.new(t_max)
      weights_log_weights = ::Array.new(t_max)
      sum_w = 0.0
      sum_w_log_w = 0.0
      t = 0
      while t < t_max
        w = tiles[t].probability.to_f
        weights[t] = w
        # `w * Math.log(w)` is NaN for w == 0 (since 0 * -Infinity = NaN),
        # which would then propagate into every cell's entropy and make
        # `find_lowest_entropy_cell` return nothing forever. The limit
        # lim_{w→0} w*log(w) is 0, so use that.
        wlogw = (w == 0.0) ? 0.0 : w * ::Math.log(w)
        weights_log_weights[t] = wlogw
        sum_w += w
        sum_w_log_w += wlogw
        t += 1
      end
      @weights = weights.freeze
      @weights_log_weights = weights_log_weights.freeze
      @initial_sum_w = sum_w
      @initial_sum_w_log_w = sum_w_log_w
      @initial_entropy = ::Math.log(sum_w) - sum_w_log_w / sum_w

      # Per-tile chunk index + Fixnum bit-within-chunk mask. Used by `ban`
      # and `observe`, where iteration is by absolute tile index.
      @chunk_of = ::Array.new(t_max) { |i| i / WAVE_CHUNK_BITS }.freeze
      @bit_in_chunk = ::Array.new(t_max) { |i| 1 << (i - (i / WAVE_CHUNK_BITS) * WAVE_CHUNK_BITS) }.freeze

      # Full-domain mask per chunk. The last chunk only has `t_max %
      # WAVE_CHUNK_BITS` tiles; everything else is 62 bits.
      @full_chunk_masks = ::Array.new(chunk_count) { |ch|
        bits = t_max - ch * WAVE_CHUNK_BITS
        bits = WAVE_CHUNK_BITS if bits > WAVE_CHUNK_BITS
        (1 << bits) - 1
      }.freeze

    end

    def build_initial_state
      n = @cells_count
      # Stack buffers reused across propagations.
      @prop_cells = []
      @prop_tiles = []
      # Pre-allocate per-cell state arrays once; setup_wave_state resets
      # them in place via Array#fill (no per-restart allocations).
      @wave_chunks = ::Array.new(@chunk_count) { ::Array.new(n) }
      @remaining = ::Array.new(n)
      @sum_w = ::Array.new(n)
      @sum_w_log_w = ::Array.new(n)
      # `entropy + noise` for find_lowest_entropy_cell. Maintained
      # eagerly on every ban so the lowest-entropy scan reads a single
      # array. Noise (jitter for tie-breaking) is baked in once at setup
      # and stays constant per cell for the run, so the addition only
      # has to happen when the entropy itself changes.
      @entropy_noise = ::Array.new(n)
      @noise = ::Array.new(n)
      @chosen_tile = ::Array.new(n)
      build_neighbours
      build_initial_compatible_template
      # Supporter-count storage. Split per direction so the inner
      # propagation loop can index by a flat `(c * t_max + t)` integer
      # (no `<<2`, no `+ opp_d`). Each is pre-allocated and reset in
      # place via Array#replace on every restart — no per-restart
      # allocations.
      @compatible_per_dir = ::Array.new(4) { ::Array.new(@cells_count * @num_tiles) }
      # Same arrays in OPP order so the propagation loop can do a single
      # array lookup per direction (`compatible_per_opp[d]`) rather than
      # `compatible_per_dir[OPP[d]]` — two Array#[] reads per direction.
      @compatible_per_opp = OPP.map { |opp_d| @compatible_per_dir[opp_d] }.freeze
    end

    # Precompute the neighbour cell index for every (cell, direction) pair,
    # stored flat at `@neighbours[c * 4 + d]`. Missing neighbours (off-grid)
    # are encoded as -1. Replaces per-iteration `c % w`, `c / w`, bounds
    # checks, and `ny * w + nx` in every hot loop that walks neighbours.
    def build_neighbours
      n = @cells_count
      w = @width
      h = @height
      neighbours = ::Array.new(n * 4)
      c = 0
      while c < n
        cx = c % w
        cy = c / w
        d = 0
        while d < 4
          nx = cx + DX[d]
          ny = cy + DY[d]
          neighbours[c * 4 + d] = if nx >= 0 && nx < w && ny >= 0 && ny < h
            ny * w + nx
          else
            -1
          end
          d += 1
        end
        c += 1
      end
      @neighbours = neighbours.freeze
    end

    # ---- per-run state (resettable on contradiction/restart) ---------------------

    def setup_wave_state
      n = @cells_count
      t_max = @num_tiles

      # Reset per-cell state in place — buffers are pre-allocated in
      # build_initial_state, so contradiction restarts don't churn the GC.
      ch = 0
      while ch < @chunk_count
        @wave_chunks[ch].fill(@full_chunk_masks[ch])
        ch += 1
      end
      @remaining.fill(t_max)
      @sum_w.fill(@initial_sum_w)
      @sum_w_log_w.fill(@initial_sum_w_log_w)
      @chosen_tile.fill(-1)
      noise = @noise
      entropy_noise = @entropy_noise
      initial_entropy = @initial_entropy
      i = 0
      while i < n
        nz = ::Kernel.rand * 1e-6
        noise[i] = nz
        entropy_noise[i] = initial_entropy + nz
        i += 1
      end
      # When the tileset has a single tile every cell is born collapsed,
      # so `complete?` must report true immediately. Fill must come after
      # the generic `-1` fill above so we overwrite, not the other way.
      if t_max == 1
        @chosen_tile.fill(0)
        @uncollapsed_count = 0
      else
        @uncollapsed_count = n
      end
      @contradiction = false
      @prop_cells.clear
      @prop_tiles.clear

      d = 0
      while d < 4
        @compatible_per_dir[d].replace(@initial_compatible_per_dir[d])
        d += 1
      end
      orphan_ban_pass
      propagate
      @generation += 1
    end

    # The initial supporter-count arrays are fully determined by the tileset
    # and grid dimensions, so build them once and `replace` per run instead
    # of repeating the border-patch pass on every contradiction restart.
    # One Array per direction; index by `c * t_max + t`.
    def build_initial_compatible_template
      n = @cells_count
      t_max = @num_tiles
      neighbours = @neighbours
      propagator_counts = @propagator_counts

      @initial_compatible_per_dir = ::Array.new(4) do |d|
        counts = propagator_counts[d]
        arr = ::Array.new(n * t_max)
        c = 0
        while c < n
          base = c * t_max
          if neighbours[c * 4 + d] < 0
            # Missing neighbour in this direction: sentinel 255 so
            # `orphan_ban_pass` can't see a zero and incorrectly ban
            # tiles at the boundary.
            t = 0
            while t < t_max
              arr[base + t] = 255
              t += 1
            end
          else
            t = 0
            while t < t_max
              arr[base + t] = counts[t]
              t += 1
            end
          end
          c += 1
        end
        arr.freeze
      end
      @initial_compatible_per_dir.freeze
      # Sentinel 255-filled array reused by rebuild_compatible_from_wave
      # to clear arrays in place without allocating an intermediate.
      @compatible_fill = ::Array.new(n * t_max, 255).freeze
    end

    def rebuild_compatible_from_wave
      n = @cells_count
      t_max = @num_tiles
      neighbours = @neighbours
      propagator_chunks = @propagator_chunks
      wave_chunks = @wave_chunks
      chunk_count = @chunk_count
      compatible_per_dir = @compatible_per_dir

      d = 0
      while d < 4
        compatible_per_dir[d].replace(@compatible_fill)
        d += 1
      end

      c = 0
      while c < n
        d = 0
        while d < 4
          nc = neighbours[c * 4 + d]
          if nc >= 0
            compat_d = compatible_per_dir[d]
            base_c = c * t_max
            t = 0
            while t < t_max
              cnt = 0
              ch = 0
              while ch < chunk_count
                cnt += popcount(propagator_chunks[d][t][ch] & wave_chunks[ch][nc])
                ch += 1
              end
              cnt = 255 if cnt > 255
              compat_d[base_c + t] = cnt
              t += 1
            end
          end
          d += 1
        end
        c += 1
      end
    end

    def orphan_ban_pass
      n = @cells_count
      t_max = @num_tiles
      compatible_per_dir = @compatible_per_dir
      compat_d0 = compatible_per_dir[0]
      compat_d1 = compatible_per_dir[1]
      compat_d2 = compatible_per_dir[2]
      compat_d3 = compatible_per_dir[3]
      wave_chunks = @wave_chunks
      chunk_count = @chunk_count

      c = 0
      while c < n
        base_c = c * t_max
        ch = 0
        while ch < chunk_count
          v = wave_chunks[ch][c]
          tile_offset = ch * WAVE_CHUNK_BITS
          while v != 0
            lowest = v & -v
            t = tile_offset + lowest.bit_length - 1
            base = base_c + t
            if compat_d0[base] == 0 ||
                compat_d1[base] == 0 ||
                compat_d2[base] == 0 ||
                compat_d3[base] == 0
              ban(c, t)
            end
            v ^= lowest
          end
          ch += 1
        end
        c += 1
      end
    end

    # ---- core observe / ban / propagate -----------------------------------------

    def observe_and_propagate
      restarts = 0
      loop do
        c = find_lowest_entropy_cell
        return false unless c

        observe(c)
        propagate

        if @contradiction
          restarts += 1
          if restarts > MAX_RESTARTS
            ::Kernel.raise(
              ::WaveFunctionCollapse::Error,
              "exceeded #{MAX_RESTARTS} consecutive contradiction " \
              "restarts; the tileset may be inherently unsolvable on " \
              "this grid"
            )
          end
          # Restart: rebuild wave state and try again.
          setup_wave_state
          next
        end
        @generation += 1
        return true
      end
    end

    def find_lowest_entropy_cell
      n = @cells_count
      remaining = @remaining
      entropy_noise = @entropy_noise
      best_c = -1
      best_e = ::Float::INFINITY
      c = 0
      while c < n
        if remaining[c] > 1
          e = entropy_noise[c]
          if e < best_e
            best_e = e
            best_c = c
          end
        end
        c += 1
      end
      best_c < 0 ? nil : best_c
    end

    def observe(c)
      total = @sum_w[c]
      r = ::Kernel.rand * total

      weights = @weights
      wave_chunks = @wave_chunks
      chunk_count = @chunk_count

      chosen = -1
      ch = 0
      while ch < chunk_count
        v = wave_chunks[ch][c]
        tile_offset = ch * WAVE_CHUNK_BITS
        while v != 0
          lowest = v & -v
          t = tile_offset + lowest.bit_length - 1
          r -= weights[t]
          if r <= 0
            chosen = t
            break
          end
          v ^= lowest
        end
        break if chosen >= 0
        ch += 1
      end

      if chosen < 0
        # Floating-point edge: pick the highest set bit across chunks.
        ch = chunk_count - 1
        while ch >= 0
          v = wave_chunks[ch][c]
          if v != 0
            chosen = ch * WAVE_CHUNK_BITS + v.bit_length - 1
            break
          end
          ch -= 1
        end
      end

      # Ban every other tile at this cell. Snapshot chunks before iterating
      # because `ban` mutates them in place — we want to ban every tile that
      # was alive *before* this observation, not the shrinking set.
      ch = 0
      while ch < chunk_count
        v = wave_chunks[ch][c]
        tile_offset = ch * WAVE_CHUNK_BITS
        while v != 0
          lowest = v & -v
          t = tile_offset + lowest.bit_length - 1
          if t != chosen
            ban(c, t)
            return if @contradiction
          end
          v ^= lowest
        end
        ch += 1
      end
    end

    def ban(c, t)
      ch = @chunk_of[t]
      b = @bit_in_chunk[t]
      wave_ch = @wave_chunks[ch]
      v = wave_ch[c]
      return if (v & b) == 0

      v ^= b
      wave_ch[c] = v
      @remaining[c] -= 1

      w = @weights[t]
      wlogw = @weights_log_weights[t]
      @sum_w[c] -= w
      @sum_w_log_w[c] -= wlogw

      r = @remaining[c]
      if r == 0
        @contradiction = true
        return
      end

      s = @sum_w[c]
      @entropy_noise[c] = ::Math.log(s) - @sum_w_log_w[c] / s + @noise[c]

      if r == 1
        @uncollapsed_count -= 1
        @chosen_tile[c] = find_single_tile(c)
      end

      @prop_cells.push(c)
      @prop_tiles.push(t)
    end

    # Locate the single remaining tile across `@wave_chunks` for cell `c`.
    # Only called when `@remaining[c]` just dropped to 1, so exactly one
    # chunk has a non-zero entry with a single set bit.
    def find_single_tile(c)
      ch = @chunk_count - 1
      while ch >= 0
        v = @wave_chunks[ch][c]
        return ch * WAVE_CHUNK_BITS + v.bit_length - 1 if v != 0
        ch -= 1
      end
      -1
    end

    def propagate
      prop_cells = @prop_cells
      prop_tiles = @prop_tiles
      propagator_chunks = @propagator_chunks
      compatible_per_opp = @compatible_per_opp
      wave_chunks = @wave_chunks
      neighbours = @neighbours
      t_max = @num_tiles
      remaining = @remaining
      sum_w = @sum_w
      sum_w_log_w = @sum_w_log_w
      entropy_noise = @entropy_noise
      noise = @noise
      weights = @weights
      weights_log_weights = @weights_log_weights
      chosen_tile = @chosen_tile
      chunk_count = @chunk_count
      chunk_bits = WAVE_CHUNK_BITS

      until prop_cells.empty?
        return if @contradiction
        t = prop_tiles.pop
        c = prop_cells.pop
        c4 = c * 4

        d = 0
        while d < 4
          nc = neighbours[c4 + d]
          if nc >= 0
            # Single Array indexed by `nc * t_max + tp` for this
            # direction's supporter counts. Avoids the `<<2` + `+opp_d`
            # arithmetic the interleaved-byte-buffer layout required.
            compat = compatible_per_opp[d]
            nc_base = nc * t_max
            prop_dt = propagator_chunks[d][t]

            ch = 0
            while ch < chunk_count
              prop_mask = prop_dt[ch]
              if prop_mask != 0
                wave_ch = wave_chunks[ch]
                wnc = wave_ch[nc]
                # Intersection: tiles that are both still alive at the
                # neighbour and compatible with originating tile t in
                # direction d. Iterating set bits of `m` walks exactly
                # the tiles that need a supporter-count decrement.
                m = wnc & prop_mask
                tile_offset = ch * chunk_bits
                nc_base_ch = nc_base + tile_offset
                while m != 0
                  lowest = m & -m
                  bit_pos = lowest.bit_length - 1
                  idx = nc_base_ch + bit_pos
                  count = compat[idx] - 1
                  compat[idx] = count
                  if count == 0
                    # Inlined fast-path of `ban(nc, tp)`. We know the bit
                    # is set in this chunk (from the intersection), so
                    # subtracting the single-bit `lowest` flips it off.
                    wnc -= lowest
                    wave_ch[nc] = wnc
                    tp = tile_offset + bit_pos
                    new_remaining = remaining[nc] - 1
                    remaining[nc] = new_remaining
                    sum_w[nc] -= weights[tp]
                    sum_w_log_w[nc] -= weights_log_weights[tp]
                    if new_remaining == 0
                      @contradiction = true
                      return
                    end
                    s = sum_w[nc]
                    entropy_noise[nc] = ::Math.log(s) - sum_w_log_w[nc] / s + noise[nc]
                    if new_remaining == 1
                      @uncollapsed_count -= 1
                      chosen_tile[nc] = find_single_tile(nc)
                    end
                    prop_cells.push(nc)
                    prop_tiles.push(tp)
                  end
                  # `m -= lowest` clears the lowest set bit (the bit we
                  # just processed) without touching the others — same
                  # effect as `m ^= lowest` but consistently faster in
                  # the interpreter on this branch.
                  m -= lowest
                end
              end
              ch += 1
            end
          end
          d += 1
        end
      end
    end

    # ---- helpers ----------------------------------------------------------------

    def tile_at(x, y)
      t = @chosen_tile[y * @width + x]
      t < 0 ? nil : @tiles[t]
    end

    def shift_uniform!(arr, shift_count, fill_value)
      w = @width
      i = 0
      while i < shift_count
        arr[i] = arr[i + w]
        i += 1
      end
      n = arr.length
      while i < n
        arr[i] = fill_value
        i += 1
      end
    end

    def popcount(x)
      c = 0
      while x > 0
        c += 1 if (x & 1) != 0
        x >>= 1
      end
      c
    end
  end
end
