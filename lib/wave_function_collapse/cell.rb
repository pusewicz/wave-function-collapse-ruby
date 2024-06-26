module WaveFunctionCollapse
  class Cell < BasicObject
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
end
