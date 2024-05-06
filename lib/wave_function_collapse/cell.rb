module WaveFunctionCollapse
  class Cell
    attr_accessor :collapsed, :entropy, :tiles, :x, :y
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

    def neighbors(grid)
      return if grid.nil?

      @neighbors["#{@x},#{@y}"] ||= begin
        up = grid[@x][@y + 1] if grid[@x] && @y < grid[0].length - 1
        down = grid[@x][@y - 1] if grid[@x] && @y.positive?
        right = grid[@x + 1][@y] if @x < grid.length - 1
        left = grid[@x - 1][@y] if @x.positive?
        {up: up, down: down, right: right, left: left}
      end
    end
  end
end
