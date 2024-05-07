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
      @uncollapsed_cells = @cells.reject(&:collapsed)
      @max_entropy = @tiles.length
    end

    def cell_at(x, y)
      @cells[@width * y + x]
    end

    def complete?
      @uncollapsed_cells.empty?
    end

    def percent
      ((@width * @height) - @uncollapsed_cells.length.to_f) / (@width * @height) * 100
    end

    def solve
      cell = random_cell
      process_cell(cell)
      generate_grid
    end

    def iterate
      return false if @uncollapsed_cells.empty?

      next_cell = find_lowest_entropy
      return false unless next_cell

      process_cell(next_cell)
      generate_grid
    end

    def prepend_empty_row
      @cells = @cells.drop(@width)
      @cells.each { |cell| cell.y -= 1 }
      x = 0
      while x < @width
        new_cell = Cell.new(x, @height - 1, @tiles)
        @cells << new_cell
        @uncollapsed_cells << new_cell
        x += 1
      end
      @width.times { |x|
        evaluate_neighbor(cell_at(x, @height - 2), :up)
      }
    end

    def random_cell
      @uncollapsed_cells.sample
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
      @uncollapsed_cells.delete(cell)
      return if @uncollapsed_cells.empty?

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
      @uncollapsed_cells.delete(neighbor_cell) if neighbor_cell.collapsed

      # if the number of tiles changed, we need to evaluate current cell's neighbors now
      propagate(neighbor_cell) if neighbor_cell.tiles.length != original_tile_count
    end

    def find_lowest_entropy
      ucg = @uncollapsed_cells
      i = 0
      l = ucg.length
      min_e = ucg[0].entropy
      acc = []
      while i < l
        cc = ucg[i]
        next i += 1 if !cc

        ce = cc.entropy
        if ce < min_e
          min_e = ce
          acc.clear
          acc << i
        elsif ce == min_e
          acc << i
        end

        i += 1
      end
      ucg[acc.sample]
    end
  end
end
