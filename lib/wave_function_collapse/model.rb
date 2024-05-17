module WaveFunctionCollapse
  class Model
    MAX_ITERATIONS = 5_000

    DIRECTION_TO_INDEXES = {
      up: [7, 0, 1],
      right: [1, 2, 3],
      down: [5, 4, 3],
      left: [7, 6, 5]
    }.freeze

    OPPOSITE_OF = {
      up: :down,
      right: :left,
      down: :up,
      left: :right
    }.freeze

    attr_reader :tiles, :width, :height, :cells, :max_entropy

    def initialize(tiles, width, height)
      @tiles = tiles
      @width = width.to_i
      @height = height.to_i
      @cells = []
      @height.times { |y| @width.times { |x| @cells << Cell.new(x, y, @tiles.shuffle) } }
      @uncollapsed_cells_indexes = (0...(width * height)).to_a
      @max_entropy = @tiles.length
    end

    def cell_at(x, y)
      @cells[@width * y + x]
    end

    def complete?
      @uncollapsed_cells_indexes.empty?
    end

    def percent
      size = @width * @height
      (size - @uncollapsed_cells_indexes.length.to_f) / size * 100
    end

    def solve
      cell = random_cell
      process_cell(cell)
      generate_grid
    end

    def iterate
      return false if @uncollapsed_cells_indexes.empty?

      next_cell = find_lowest_entropy
      return false unless next_cell

      process_cell(next_cell)
      generate_grid
    end

    def prepend_empty_row
      @cells = @cells.drop(@width)
      @cells.each { |cell| cell.y -= 1 }
      x = 0
      y = @height - 1
      while x < @width
        @cells << Cell.new(x, y, @tiles)
        idx = (@width * y) + x
        @uncollapsed_cells_indexes << idx
        evaluate_neighbor(cell_at(x, y - 1), :up)
        x += 1
      end
    end

    def random_cell
      @cells[@uncollapsed_cells_indexes.sample]
    end

    def generate_grid
      x = 0
      result = []

      while x < @width
        rx = result[x] = []
        y = 0

        while y < @height
          rx[y] = cell_at(x, y).tile
          y += 1
        end
        x += 1
      end

      result
    end

    def process_cell(cell)
      cell.collapse

      idx = (@width * cell.y) + cell.x
      @uncollapsed_cells_indexes.delete_at(
        @uncollapsed_cells_indexes.bsearch_index { |i| i >= idx }
      )
      return if @uncollapsed_cells_indexes.empty?

      propagate(cell)
    end

    def propagate(source_cell)
      evaluate_neighbor(source_cell, :up)
      evaluate_neighbor(source_cell, :right)
      evaluate_neighbor(source_cell, :down)
      evaluate_neighbor(source_cell, :left)
    end

    def evaluate_neighbor(source_cell, evaluation_direction)
      neighbor_cell = source_cell.neighbors(self)[evaluation_direction] || return
      return if neighbor_cell.collapsed

      original_tile_count = neighbor_cell.tiles.length
      opposite_direction = OPPOSITE_OF[evaluation_direction]
      neighbor_tiles = neighbor_cell.tiles

      source_tile_edges = source_cell.tiles.map do |source_tile|
        case evaluation_direction
        when :up then source_tile.up
        when :right then source_tile.right
        when :down then source_tile.down
        when :left then source_tile.left
        end
      end

      opposite_tile_edges = neighbor_tiles.map do |opposite_tile|
        case opposite_direction
        when :up then opposite_tile.up
        when :right then opposite_tile.right
        when :down then opposite_tile.down
        when :left then opposite_tile.left
        end
      end

      new_tiles = []
      ntc = neighbor_tiles.length
      i = 0
      while i < ntc
        ii = 0
        stel = source_tile_edges.length
        while ii < stel
          if source_tile_edges[ii] == opposite_tile_edges[i]
            new_tiles << neighbor_tiles[i]
            break
          end
          ii += 1
        end
        i += 1
      end

      neighbor_cell.tiles = new_tiles unless new_tiles.empty?
      if neighbor_cell.collapsed
        idx = (@width * neighbor_cell.y) + neighbor_cell.x

        @uncollapsed_cells_indexes.delete_at(
          @uncollapsed_cells_indexes.bsearch_index { |i| i >= idx }
        )
      end

      # if the number of tiles changed, we need to evaluate current cell's neighbors now
      propagate(neighbor_cell) if neighbor_cell.tiles.length != original_tile_count
    end

    def find_lowest_entropy
      ucg = @uncollapsed_cells_indexes
      len = ucg.length
      idx = ucg[0]
      min_e = @cells[idx].entropy
      acc = []
      i = 0
      while i < len
        idx2 = ucg[i]
        cc = @cells[idx2]

        ce = cc.entropy
        if ce < min_e
          min_e = ce
          acc = [idx2]
        elsif ce == min_e
          acc << idx2
        end

        i += 1
      end
      @cells[acc.sample]
    end
  end
end
