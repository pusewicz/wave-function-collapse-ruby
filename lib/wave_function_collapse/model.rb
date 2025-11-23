require "set"

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
      build_tile_adjacencies
      @height.times { |y| @width.times { |x| @cells << Cell.new(x, y, @tiles.shuffle) } }
      @uncollapsed_cells = Set.new(@cells.reject(&:collapsed))
      @max_entropy = @tiles.length
    end

    def build_tile_adjacencies
      # Pre-compute which tiles can be adjacent in each direction
      # This transforms the O(n²) runtime matching into O(1) lookup
      # We build a mapping from edge hash -> list of tiles with that edge in opposite direction
      @edge_to_tiles = {}

      [:up, :right, :down, :left].each do |direction|
        @edge_to_tiles[direction] = {}

        opposite_direction = OPPOSITE_OF[direction]

        # For each tile, index it by its opposite edge
        @tiles.each do |tile|
          opposite_edge = case opposite_direction
          when :up then tile.up
          when :right then tile.right
          when :down then tile.down
          when :left then tile.left
          end

          @edge_to_tiles[direction][opposite_edge] ||= []
          @edge_to_tiles[direction][opposite_edge] << tile
        end
      end
    end

    def cell_at(x, y)
      @cells[@width * y + x]
    end

    def complete?
      @uncollapsed_cells.empty?
    end

    def percent
      ((@width * @height) - @uncollapsed_cells.size.to_f) / (@width * @height) * 100
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
        @uncollapsed_cells.add(new_cell)
        x = x.succ
      end
      @width.times { |x|
        evaluate_neighbor(cell_at(x, @height - 2), :up)
      }
    end

    def random_cell
      @uncollapsed_cells.to_a.sample
    end

    def generate_grid
      x = 0
      result = []

      while x < @width
        rx = result[x] = []
        y = 0

        while y < @height
          rx[y] = cell_at(x, y).tile
          y = y.succ
        end
        x = x.succ
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
      neighbor_tiles = neighbor_cell.tiles

      # Collect all valid adjacent tiles from all source tiles
      # Using pre-computed edge-to-tiles lookup with fast intersection via object_id
      valid_tile_ids = {}
      source_cell.tiles.each do |source_tile|
        # Get the edge of this source tile in the evaluation direction
        source_edge = case evaluation_direction
        when :up then source_tile.up
        when :right then source_tile.right
        when :down then source_tile.down
        when :left then source_tile.left
        end

        # Look up all tiles that can be adjacent (pre-computed)
        compatible_tiles = @edge_to_tiles[evaluation_direction][source_edge]
        if compatible_tiles
          compatible_tiles.each do |tile|
            valid_tile_ids[tile.__id__] = tile
          end
        end
      end

      # Keep only neighbor tiles that are in the valid set (O(n) intersection)
      new_tiles = []
      neighbor_tiles.each do |neighbor_tile|
        new_tiles << neighbor_tile if valid_tile_ids[neighbor_tile.__id__]
      end

      neighbor_cell.tiles = new_tiles unless new_tiles.empty?
      @uncollapsed_cells.delete(neighbor_cell) if neighbor_cell.collapsed

      # if the number of tiles changed, we need to evaluate current cell's neighbors now
      propagate(neighbor_cell) if neighbor_cell.tiles.length != original_tile_count
    end

    def find_lowest_entropy
      return nil if @uncollapsed_cells.empty?

      min_e = nil
      acc = []

      @uncollapsed_cells.each do |cell|
        ce = cell.entropy

        if min_e.nil? || ce < min_e
          min_e = ce
          acc.clear
          acc << cell
        elsif ce == min_e
          acc << cell
        end
      end

      acc.sample
    end
  end
end
