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

    attr_reader :tiles, :width, :height, :grid, :max_entropy

    def initialize(tiles, width, height)
      @tiles = tiles
      @width = width.to_i
      @height = height.to_i
      @grid = []
      @height.times { |y| @width.times { |x| @grid << Cell.new(x, y, @tiles.shuffle) } }
      @uncollapsed_cells_grid = @grid.reject(&:collapsed)
      @max_entropy = @tiles.length
    end

    def cell_at(x, y)
      @grid[@width * y + x]
    end

    def complete?
      @uncollapsed_cells_grid.empty?
    end

    def percent
      ((@width * @height) - @uncollapsed_cells_grid.length.to_f) / (@width * @height) * 100
    end

    def solve
      cell = random_cell
      process_cell(cell)
      generate_grid
    end

    def iterate
      return false if @uncollapsed_cells_grid.empty?

      next_cell = find_lowest_entropy
      return false unless next_cell

      process_cell(next_cell)
      generate_grid
    end

    def prepend_empty_row
      x = 0
      while x < @width
        @grid[x].shift
        y = 0
        while y < @height - 1
          @grid[x][y].y -= 1
          y += 1
        end
        new_cell = Cell.new(x, @height - 1, @tiles)
        @grid[x] << new_cell
        @uncollapsed_cells_grid << new_cell
        x += 1
      end

      @width.times do |x|
        evaluate_neighbor(@grid[x][@height - 2], :up)
      end
    end

    def random_cell
      @uncollapsed_cells_grid.sample
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
      @uncollapsed_cells_grid.delete(cell)
      return if @uncollapsed_cells_grid.empty?

      propagate(cell)
    end

    def propagate(source_cell)
      evaluate_neighbor(source_cell, :up)
      evaluate_neighbor(source_cell, :right)
      evaluate_neighbor(source_cell, :down)
      evaluate_neighbor(source_cell, :left)
    end

    def evaluate_neighbor(source_cell, evaluation_direction)
      neighbor_cell = source_cell.neighbors(self)[evaluation_direction]
      return if neighbor_cell.nil? || neighbor_cell.collapsed

      original_tile_count = neighbor_cell.tiles.length
      opposite_direction = OPPOSITE_OF[evaluation_direction]

      new_tile_ids = {}
      new_tiles = []
      source_tiles = source_cell.tiles
      neighbor_tiles = neighbor_cell.tiles
      sci = 0
      scil = source_tiles.length



      while sci < scil
        source_tile = source_tiles[sci]
        sci += 1
        source_edge_hash = case evaluation_direction
        when :up then source_tile.up
        when :right then source_tile.right
        when :down then source_tile.down
        when :left then source_tile.left
        end
        nci = 0
        ncil = neighbor_tiles.length

        while nci < ncil
          tile = neighbor_tiles[nci]
          nci += 1
          next if new_tile_ids.has_key?(tile.tileid)

          tile_edge_hash = case opposite_direction
          when :up then tile.up
          when :right then tile.right
          when :down then tile.down
          when :left then tile.left
          end
          if tile_edge_hash == source_edge_hash
            new_tile_ids[tile.tileid] = true
            new_tiles << tile
          end
        end
      end

      neighbor_cell.tiles = new_tiles unless new_tiles.empty?
      @uncollapsed_cells_grid.delete(neighbor_cell) if neighbor_cell.collapsed

      # if the number of tiles changed, we need to evaluate current cell's neighbors now
      propagate(neighbor_cell) if neighbor_cell.tiles.length != original_tile_count
    end

    def find_lowest_entropy
      ucg = @uncollapsed_cells_grid.to_a
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
          acc << cc
        elsif ce == min_e
          acc << cc
        end

        i += 1
      end
      acc.sample
    end
  end
end
