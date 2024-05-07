require "json"

module WaveFunctionCollapse
  class Window < Gosu::Window
    WIDTH = 1280
    HEIGHT = 800
    def initialize
      super(WIDTH, HEIGHT)
      self.caption = "Wave Function Collapse in Ruby"
      @font = Gosu::Font.new(14)
      @small_font = Gosu::Font.new(12)
      @map_json = JSON.load_file!("assets/map.tsj")
      @tile_width = @map_json["tilewidth"]
      @tile_height = @map_json["tileheight"]
      @tiles = Gosu::Image.load_tiles("assets/#{@map_json["image"]}", @tile_width, @tile_height, tileable: true)
      @times = []
      @paused = false
      @labels = []
      @model = nil
      @map = nil
      @started_at = nil
      @finished_at = nil
      defaults
    end

    def defaults
      @model = Model.new(build_tiles, WIDTH.div(@tile_width), HEIGHT.div(@tile_height))
      @map = nil
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @finished_at = nil
    end

    def update
      @labels = []
      @map = @model.solve if @map.nil?

      return if @paused

      unless @model.complete?
        time_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @map = @model.iterate
        @times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - time_start
      end
    end

    def draw
      if @model.complete?
        @finished_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        time = @finished_at - @started_at
        add_label("Map generated in #{"%02.2f" % time}s")
        add_label("Press A to add row.")
      else
        time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
        add_label("Generating #{@model.width}x#{@model.height}. Elapsed #{"%02.2f" % time}s. #{"%02.2f" % @model.percent}% complete.")
        add_label("Press P to pause/unpause, R to restart.")
      end
      if (last_time = @times.last)
        mss = last_time * 1000
        color = (mss > 16) ? Gosu::Color::RED : Gosu::Color::GREEN
        add_label("Last iteration: #{"%03.2f" % mss}ms", color)
      end
      draw_map

      average_time_mss = (@times.sum / @times.size.to_f) * 1000
      add_label("AVG(mss)=#{"%03.2f" % average_time_mss}ms", (average_time_mss > 16) ? Gosu::Color::RED : Gosu::Color::GREEN)

      p90_time = @times.sort[(@times.size * 0.9).to_i] * 1000
      add_label("P90(mss)=#{"%03.2f" % p90_time}ms", (p90_time > 16) ? Gosu::Color::RED : Gosu::Color::GREEN)

      p99_time = @times.sort[(@times.size * 0.99).to_i] * 1000
      add_label("P99(mss)=#{"%03.2f" % p99_time}ms", (p99_time > 16) ? Gosu::Color::RED : Gosu::Color::GREEN)

      if @paused
        @font.draw_text_rel("Paused", WIDTH / 2, HEIGHT / 2, ZOrder::UI, 0.5, 0.5)
      end

      draw_labels
    end

    def button_down(id)
      case id
      when Gosu::KB_R
        puts "Restarting..."
        defaults
      when Gosu::KB_A
        if @model.complete?
          puts "Adding empty row..."
          @times = []
          @model.prepend_empty_row
        end
      when Gosu::KB_P
        @paused = !@paused
      when Gosu::KB_S
        puts "Solving..."
        @model.solve
      end
    end

    private

    def version_label
      @label ||= [[RUBY_ENGINE, RUBY_VERSION].join("/"), ["gosu", Gosu::VERSION].join("/"), RUBY_PLATFORM].join(" ")
    end

    def add_label(text, color = Gosu::Color::WHITE)
      @labels << [text, color]
    end

    def draw_labels
      @labels.each_with_index do |(text, color), offset|
        @font.draw_text(text, 5, 5 + (offset * @font.height * 1.2), ZOrder::UI, 1.0, 1.0, Gosu::Color::BLACK)
        @font.draw_text(text, 4, 4 + (offset * @font.height * 1.2), ZOrder::UI, 1.0, 1.0, color)
      end

      @small_font.draw_text_rel(version_label, WIDTH - 3, HEIGHT - 1, ZOrder::UI, 1.0, 1.0, 1, 1, Gosu::Color::BLACK)
      @small_font.draw_text_rel(version_label, WIDTH - 4, HEIGHT - 2, ZOrder::UI, 1.0, 1.0, 1, 1, Gosu::Color::GRAY)
    end

    def draw_map
      @map.each_with_index do |column, x|
        column.reverse.each_with_index do |tile, y|
          inverted_y = (y - @model.height + 1).abs

          entropy = @model.cell_at(x, inverted_y).entropy

          if entropy > 1
            percent_entropy = (entropy.to_f / @model.max_entropy * 255).round
            color = Gosu::Color.new(160, percent_entropy, 255 - percent_entropy, 0)
            @small_font.draw_text_rel(
              entropy,
              x * @tile_width + (@tile_width / 2),
              y * @tile_height + (@tile_height / 2),
              ZOrder::MAP, 0.5, 0.5, 1, 1, color
            )
          end

          next unless tile

          image = @tiles[tile.tileid]
          image.draw(x * @tile_width, y * @tile_height, ZOrder::MAP)
        end
      end
    end

    def build_tiles
      @map_json["wangsets"].last["wangtiles"].map do |tile|
        # TODO: Probability can also be defined in the wangset
        prob = @map_json["tiles"]&.find { |t| t["id"] == tile["tileid"] }&.fetch("probability")
        Tile.new(
          tileid: tile["tileid"],
          wangid: tile["wangid"],
          probability: prob
        )
      end
    end
  end
end
