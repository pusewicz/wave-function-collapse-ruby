# frozen_string_literal: true

module WaveFunctionCollapse
  # Snapshot of the original Model and Cell implementation, preserved verbatim
  # so the benchmark can measure the speedup of the rewrite. Not used at runtime
  # by the Window or the default `WaveFunctionCollapse::Model`.
  class LegacyCell < BasicObject
    @@cellid = 0
    attr_reader :tiles, :cellid
    attr_accessor :collapsed, :entropy, :x, :y
    alias_method :collapsed?, :collapsed

    def initialize(x, y, tiles)
      @cellid = @@cellid
      @collapsed = tiles.size == 1
      @entropy = tiles.size
      @tiles = tiles
      @neighbors = {}
      @x = x
      @y = y
      @@cellid = @@cellid.succ
    end

    def ==(other)
      @cellid == other.cellid
    end

    def tiles=(new_tiles)
      @tiles = new_tiles
      update
    end

    def update
      @entropy = @tiles.size
      @collapsed = @entropy == 1
    end

    def tile
      @tiles[0] if @collapsed
    end

    def collapse
      self.tiles = [@tiles.max_by { |t| ::Kernel.rand**(1.0 / t.probability) }]
    end

    def neighbors(model)
      @neighbors[model.width * y + x] ||= begin
        up = model.cell_at(@x, @y + 1) if @y < model.height - 1
        down = model.cell_at(@x, @y - 1) if @y.positive?
        right = model.cell_at(@x + 1, @y) if @x < model.width - 1
        left = model.cell_at(@x - 1, @y) if @x.positive?

        {up: up, down: down, right: right, left: left}
      end
    end
  end

  class LegacyModel
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
      @height.times { |y| @width.times { |x| @cells << LegacyCell.new(x, y, @tiles.shuffle) } }
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
        new_cell = LegacyCell.new(x, @height - 1, @tiles)
        @cells << new_cell
        @uncollapsed_cells << new_cell
        x = x.succ
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
      opposite_direction = OPPOSITE_OF[evaluation_direction]

      valid_edges = {}
      source_cell.tiles.each do |source_tile|
        valid_edges[source_tile.__send__(evaluation_direction)] = true
      end

      neighbor_tiles = neighbor_cell.tiles
      new_tiles = []
      i = 0
      ntc = neighbor_tiles.length
      while i < ntc
        tile = neighbor_tiles[i]
        new_tiles << tile if valid_edges[tile.__send__(opposite_direction)]
        i = i.succ
      end

      neighbor_cell.tiles = new_tiles unless new_tiles.empty?
      @uncollapsed_cells.delete(neighbor_cell) if neighbor_cell.collapsed

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
        next i = i.succ if !cc

        ce = cc.entropy
        if ce < min_e
          min_e = ce
          acc.clear
          acc << i
        elsif ce == min_e
          acc << i
        end

        i = i.succ
      end
      ucg[acc.sample]
    end
  end
end
