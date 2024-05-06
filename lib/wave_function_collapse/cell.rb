module WaveFunctionCollapse
  class Cell
    attr_reader :tiles
    attr_accessor :collapsed, :entropy, :x, :y
    alias_method :collapsed?, :collapsed

    def initialize(x, y, tiles)
      @collapsed = tiles.size == 1
      @entropy = tiles.size
      @tiles = tiles
      @neighbors = {}
      @x = x
      @y = y
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
      @tiles.first if @collapsed
    end

    def collapse
      return if @tiles.nil?

      self.tiles = [@tiles.max_by { |t| rand**(1.0 / t.probability) }]
    end

    def neighbors(model)
      return if model.nil?

      @neighbors[model.width * y + x] ||= begin
        up = model.grid_cell(@x, @y + 1) if @y < model.height - 1
        down = model.grid_cell(@x, @y - 1) if @y.positive?
        right = model.grid_cell(@x + 1, @y) if @x < model.width - 1
        left = model.grid_cell(@x - 1, @y) if @x.positive?

        {up: up, down: down, right: right, left: left}
      end
    end
  end
end
