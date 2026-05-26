# frozen_string_literal: true

module WaveFunctionCollapse
  # Wave Function Collapse — bitmask wave + AC-4 compatible counter.
  #
  # Each cell's domain is a single Integer bitmask (`@wave[c]`). Adjacency is
  # precomputed as `@propagator[d][t]` masks and `@propagator_lists[d][t]`
  # index arrays. Supporter counts are kept in a flat byte buffer
  # (`@compatible`, addressed via `setbyte`/`getbyte`) — when a count hits
  # zero the tile is banned at that cell, which kicks off iterative
  # propagation through an explicit stack. Entropy is maintained
  # incrementally per cell.
  class Model
    DX = [0, 1, 0, -1].freeze
    DY = [1, 0, -1, 0].freeze
    OPP = [2, 3, 0, 1].freeze

    attr_reader :tiles, :width, :height, :max_entropy

    def initialize(tiles, width, height)
      @tiles = tiles
      @width = width.to_i
      @height = height.to_i
      @num_tiles = tiles.length
      @max_entropy = @num_tiles
      @cells_count = @width * @height

      build_propagator
      build_initial_state
      setup_wave_state
    end

    def complete?
      @uncollapsed_count == 0
    end

    def percent
      (@cells_count - @uncollapsed_count).to_f / @cells_count * 100
    end

    def entropy_at(x, y)
      @remaining[y * @width + x]
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

      # Shift state down: drop bottom row (cells 0..w-1), append new top row.
      @wave = @wave[w, n - w] + Array.new(w, @full_mask)
      @remaining = @remaining[w, n - w] + Array.new(w, @num_tiles)
      @sum_w = @sum_w[w, n - w] + Array.new(w, @initial_sum_w)
      @sum_w_log_w = @sum_w_log_w[w, n - w] + Array.new(w, @initial_sum_w_log_w)
      @entropies = @entropies[w, n - w] + Array.new(w, @initial_entropy)
      @noise = @noise[w, n - w] + Array.new(w) { ::Kernel.rand * 1e-6 }
      @chosen_tile = @chosen_tile[w, n - w] + Array.new(w, -1)

      @uncollapsed_count = 0
      c = 0
      while c < n
        @uncollapsed_count += 1 if @remaining[c] > 1
        c += 1
      end

      rebuild_compatible_from_wave
      orphan_ban_pass
      propagate
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

      # propagator[d][a] = bitmask of b such that match(a, d, b) — i.e.
      # tile a's edge in dir d equals tile b's edge in opposite(d).
      propagator = ::Array.new(4) { ::Array.new(t_max, 0) }
      propagator_lists = ::Array.new(4) { ::Array.new(t_max) }

      d = 0
      while d < 4
        opp_d = OPP[d]
        my_edges = edges_per_dir[d]
        opp_edges = edges_per_dir[opp_d]
        a = 0
        while a < t_max
          my_edge = my_edges[a]
          mask = 0
          list = []
          b = 0
          while b < t_max
            if opp_edges[b] == my_edge
              mask |= (1 << b)
              list << b
            end
            b += 1
          end
          propagator[d][a] = mask
          propagator_lists[d][a] = list.freeze
          a += 1
        end
        propagator[d].freeze
        propagator_lists[d].freeze
        d += 1
      end

      @propagator = propagator.freeze
      @propagator_lists = propagator_lists.freeze

      # Weights
      weights = ::Array.new(t_max)
      weights_log_weights = ::Array.new(t_max)
      sum_w = 0.0
      sum_w_log_w = 0.0
      t = 0
      while t < t_max
        w = tiles[t].probability.to_f
        weights[t] = w
        wlogw = w * ::Math.log(w)
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

      @full_mask = (1 << t_max) - 1
      # Precomputed `1 << t` per tile — saves a Bignum allocation per
      # propagation inner iteration and ban call.
      @bit = ::Array.new(t_max) { |t| 1 << t }.freeze

      # Precompute the 4-byte-per-tile block representing an interior cell's
      # initial supporter counts (one byte per direction). Used to build the
      # @compatible buffer quickly.
      block = ::String.new(::String.new.b, capacity: t_max * 4)
      block.force_encoding(::Encoding::BINARY)
      t = 0
      while t < t_max
        block << propagator_lists[0][t].length.chr
        block << propagator_lists[1][t].length.chr
        block << propagator_lists[2][t].length.chr
        block << propagator_lists[3][t].length.chr
        t += 1
      end
      @interior_block = block.freeze
    end

    def build_initial_state
      # Stack buffers reused across propagations.
      @prop_cells = []
      @prop_tiles = []
    end

    # ---- per-run state (resettable on contradiction/restart) ---------------------

    def setup_wave_state
      n = @cells_count
      t_max = @num_tiles

      @wave = ::Array.new(n, @full_mask)
      @remaining = ::Array.new(n, t_max)
      @sum_w = ::Array.new(n, @initial_sum_w)
      @sum_w_log_w = ::Array.new(n, @initial_sum_w_log_w)
      @entropies = ::Array.new(n, @initial_entropy)
      @noise = ::Array.new(n) { ::Kernel.rand * 1e-6 }
      @chosen_tile = ::Array.new(n, -1)
      # When the tileset has a single tile every cell is born collapsed,
      # so `complete?` must report true immediately. Fill `@chosen_tile`
      # for any cell whose wave already has exactly one bit and count
      # only the genuinely undetermined cells.
      if t_max == 1
        @chosen_tile.fill(0)
        @uncollapsed_count = 0
      else
        @uncollapsed_count = n
      end
      @contradiction = false
      @prop_cells.clear
      @prop_tiles.clear

      build_initial_compatible
      orphan_ban_pass
      propagate
    end

    def build_initial_compatible
      n = @cells_count
      t_max = @num_tiles
      w = @width
      h = @height

      buf = ::String.new(::String.new.b, capacity: n * t_max * 4)
      buf.force_encoding(::Encoding::BINARY)
      c = 0
      while c < n
        buf << @interior_block
        c += 1
      end

      # Patch border cells: missing directions get sentinel 255.
      c = 0
      while c < n
        cx = c % w
        cy = c / w
        d = 0
        while d < 4
          nx = cx + DX[d]
          ny = cy + DY[d]
          unless nx >= 0 && nx < w && ny >= 0 && ny < h
            base = (c * t_max) * 4 + d
            t = 0
            while t < t_max
              buf.setbyte(base + t * 4, 255)
              t += 1
            end
          end
          d += 1
        end
        c += 1
      end

      @compatible = buf
    end

    def rebuild_compatible_from_wave
      n = @cells_count
      t_max = @num_tiles
      w = @width
      h = @height
      propagator = @propagator
      wave = @wave

      buf = ::String.new(::String.new.b, capacity: n * t_max * 4)
      buf.force_encoding(::Encoding::BINARY)
      buf << "\xff".b * (n * t_max * 4)

      c = 0
      while c < n
        cx = c % w
        cy = c / w
        d = 0
        while d < 4
          nx = cx + DX[d]
          ny = cy + DY[d]
          if nx >= 0 && nx < w && ny >= 0 && ny < h
            nc = ny * w + nx
            wmask = wave[nc]
            t = 0
            while t < t_max
              cnt = popcount(propagator[d][t] & wmask)
              cnt = 255 if cnt > 255
              buf.setbyte((c * t_max + t) * 4 + d, cnt)
              t += 1
            end
          end
          d += 1
        end
        c += 1
      end

      @compatible = buf
    end

    def orphan_ban_pass
      n = @cells_count
      t_max = @num_tiles
      compatible = @compatible
      wave = @wave
      bit_table = @bit

      c = 0
      while c < n
        t = 0
        while t < t_max
          if (wave[c] & bit_table[t]) != 0
            base = (c * t_max + t) * 4
            if compatible.getbyte(base) == 0 ||
                compatible.getbyte(base + 1) == 0 ||
                compatible.getbyte(base + 2) == 0 ||
                compatible.getbyte(base + 3) == 0
              ban(c, t)
            end
          end
          t += 1
        end
        c += 1
      end
    end

    # ---- core observe / ban / propagate -----------------------------------------

    def observe_and_propagate
      loop do
        c = find_lowest_entropy_cell
        return false unless c

        observe(c)
        propagate

        if @contradiction
          # Restart: rebuild wave state and try again.
          setup_wave_state
          next
        end
        return true
      end
    end

    def find_lowest_entropy_cell
      n = @cells_count
      remaining = @remaining
      entropies = @entropies
      noise = @noise
      best_c = -1
      best_e = ::Float::INFINITY
      c = 0
      while c < n
        if remaining[c] > 1
          e = entropies[c] + noise[c]
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
      wmask = @wave[c]
      total = @sum_w[c]
      r = ::Kernel.rand * total

      weights = @weights
      bit_table = @bit
      t_max = @num_tiles
      chosen = -1
      t = 0
      while t < t_max
        if (wmask & bit_table[t]) != 0
          r -= weights[t]
          if r <= 0
            chosen = t
            break
          end
        end
        t += 1
      end

      if chosen < 0
        # Floating-point edge: pick the last set bit in wmask.
        t = t_max - 1
        while t >= 0
          if (wmask & bit_table[t]) != 0
            chosen = t
            break
          end
          t -= 1
        end
      end

      # Ban every other tile at this cell.
      t = 0
      while t < t_max
        if t != chosen && (wmask & bit_table[t]) != 0
          ban(c, t)
          return if @contradiction
        end
        t += 1
      end
    end

    def ban(c, t)
      bit = @bit[t]
      wave = @wave
      return if (wave[c] & bit) == 0

      wave[c] = wave[c] ^ bit
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
      @entropies[c] = ::Math.log(s) - @sum_w_log_w[c] / s

      if r == 1
        @uncollapsed_count -= 1
        # Record the single remaining tile so grid() is O(1) per cell.
        mask = @wave[c]
        tt = 0
        while mask > 0
          if (mask & 1) != 0
            @chosen_tile[c] = tt
            break
          end
          mask >>= 1
          tt += 1
        end
      end

      @prop_cells.push(c)
      @prop_tiles.push(t)
    end

    def propagate
      prop_cells = @prop_cells
      prop_tiles = @prop_tiles
      propagator_lists = @propagator_lists
      compatible = @compatible
      wave = @wave
      bit_table = @bit
      t_max = @num_tiles
      w = @width
      h = @height

      until prop_cells.empty?
        return if @contradiction
        t = prop_tiles.pop
        c = prop_cells.pop

        cx = c % w
        cy = c / w

        d = 0
        while d < 4
          nx = cx + DX[d]
          ny = cy + DY[d]
          if nx >= 0 && nx < w && ny >= 0 && ny < h
            nc = ny * w + nx
            list = propagator_lists[d][t]
            opp_d = OPP[d]
            i = 0
            len = list.length
            while i < len
              tp = list[i]
              # Skip tiles already banned at the neighbour — decrementing
              # their supporter count would silently wrap past zero and
              # waste work; the bit check below would suppress the ban
              # anyway.
              if (wave[nc] & bit_table[tp]) != 0
                idx = (nc * t_max + tp) * 4 + opp_d
                count = compatible.getbyte(idx) - 1
                compatible.setbyte(idx, count)
                if count == 0
                  ban(nc, tp)
                  return if @contradiction
                end
              end
              i += 1
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
