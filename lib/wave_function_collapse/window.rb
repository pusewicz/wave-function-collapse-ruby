require "json"
require "gosu"

module WaveFunctionCollapse
  class Window < Gosu::Window
    WIDTH = 1280
    HEIGHT = 720
    # Rolling window for per-iteration timing stats. Bounded so that
    # sorting for P90/P99 each frame stays O(TIMES_CAPACITY log N) instead
    # of drifting up with run length.
    TIMES_CAPACITY = 240
    # Per-`update` budget (seconds) for running model iterations. With
    # update_interval lowered below, `update` is effectively called as
    # fast as it returns, so this controls how long we batch model work
    # before yielding back for a possible redraw.
    ITERATE_BUDGET = 0.014
    # Minimum gap (seconds) between consecutive map redraws while
    # generation is in progress. ~30 Hz is plenty for watching the wave
    # collapse, and keeps the macro rebuild from eating into iterate
    # time.
    DRAW_INTERVAL = 1.0 / 30
    # Gosu's main loop sleeps until the next update_interval boundary.
    # Default is ~16.6 ms (60 Hz); lowering it removes that idle gap so
    # we can spend the wall-clock time iterating instead. The draw rate
    # is throttled separately via `needs_redraw?`.
    UPDATE_INTERVAL_MS = 2

    def initialize
      super(WIDTH, HEIGHT)
      self.update_interval = UPDATE_INTERVAL_MS
      self.caption = "Wave Function Collapse in Ruby"
      @font = Gosu::Font.new(14)
      @small_font = Gosu::Font.new(12)
      @map_json = JSON.load_file!("assets/map.tsj")
      @tile_width = @map_json["tilewidth"]
      @tile_height = @map_json["tileheight"]
      @tiles = Gosu::Image.load_tiles("assets/#{@map_json["image"]}", @tile_width, @tile_height, tileable: true)
      @times = []
      @paused = false
      @show_entropy = true
      @last_iterates_per_frame = 0
      @labels = []
      # Pre-build the 256 entropy overlay colors so the per-cell text draw
      # doesn't allocate a Gosu::Color each call.
      @entropy_colors = Array.new(256) { |i| Gosu::Color.new(160, i, 255 - i, 0) }
      @model = nil
      @map_macro = nil
      @last_rendered_generation = -1
      @force_redraw = true
      @last_drawn_at = 0.0
      @started_at = nil
      @finished_at = nil
      defaults
    end

    def defaults
      @model = Model.new(build_tiles, WIDTH.div(@tile_width), HEIGHT.div(@tile_height))
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @finished_at = nil
      @map_macro = nil
      @last_rendered_generation = -1
      @force_redraw = true
      @last_iterates_per_frame = 0
      @last_drawn_at = 0.0
    end

    def update
      return if @paused
      return if @model.complete?

      frame_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      iters = 0
      until @model.complete?
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @model.iterate
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        @times << elapsed
        @times.shift if @times.size > TIMES_CAPACITY
        iters += 1
        break if (Process.clock_gettime(Process::CLOCK_MONOTONIC) - frame_start) >= ITERATE_BUDGET
      end
      @last_iterates_per_frame = iters
    end

    def needs_redraw?
      return true if @force_redraw
      return false if @paused
      if @model.complete?
        return @model.generation != @last_rendered_generation
      end
      # Throttle redraws while generating so the macro rebuild doesn't
      # contend with iterate for CPU. The first draw of a new state and
      # any externally-forced redraw still go through.
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_drawn_at) >= DRAW_INTERVAL
    end

    def draw
      @last_drawn_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @force_redraw = false
      @labels.clear

      if @model.generation != @last_rendered_generation
        rebuild_map_macro
        @last_rendered_generation = @model.generation
      end
      @map_macro&.draw(0, 0, ZOrder::MAP)

      if @model.complete?
        @finished_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        time = @finished_at - @started_at
        add_label("Map generated in #{"%02.2f" % time}s")
        add_label("Press A to add row.")
      else
        time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
        add_label("Generating #{@model.width}x#{@model.height}. Elapsed #{"%02.2f" % time}s. #{"%02.2f" % @model.percent}% complete.")
        add_label("Press P to pause/unpause, R to restart, E to toggle entropy overlay.")
      end

      add_label("Iterates/frame: #{@last_iterates_per_frame} | Entropy overlay: #{@show_entropy ? "ON" : "OFF"} (E)")

      if (last_time = @times.last)
        mss = last_time * 1000
        color = (mss > 16) ? Gosu::Color::RED : Gosu::Color::GREEN
        add_label("Last iteration: #{"%03.2f" % mss}ms", color)
      end

      unless @times.empty?
        sorted = @times.sort
        avg_mss = (@times.sum / @times.size.to_f) * 1000
        add_label("AVG(mss)=#{"%03.2f" % avg_mss}ms", (avg_mss > 16) ? Gosu::Color::RED : Gosu::Color::GREEN)

        p90_mss = sorted[(sorted.size * 0.9).to_i] * 1000
        add_label("P90(mss)=#{"%03.2f" % p90_mss}ms", (p90_mss > 16) ? Gosu::Color::RED : Gosu::Color::GREEN)

        p99_mss = sorted[(sorted.size * 0.99).to_i] * 1000
        add_label("P99(mss)=#{"%03.2f" % p99_mss}ms", (p99_mss > 16) ? Gosu::Color::RED : Gosu::Color::GREEN)
      end

      add_label("FPS: #{Gosu.fps}")

      if @paused
        @font.draw_text_rel("Paused", WIDTH / 2, HEIGHT / 2, ZOrder::UI, 0.5, 0.5)
      end

      draw_labels
    end

    def button_down(id)
      case id
      when Gosu::KB_R
        puts "Restarting..."
        @times = []
        defaults
      when Gosu::KB_A
        if @model.complete?
          puts "Adding empty row..."
          @times = []
          @model.prepend_empty_row
          @finished_at = nil
          @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @force_redraw = true
        end
      when Gosu::KB_P
        @paused = !@paused
        @force_redraw = true
      when Gosu::KB_E
        @show_entropy = !@show_entropy
        # Invalidate the cached macro so the toggle takes effect immediately.
        @last_rendered_generation = -1
        @force_redraw = true
      when Gosu::KB_S
        puts "Solving..."
        @model.solve
        @force_redraw = true
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

    # Re-record the full grid into a Gosu macro so subsequent frames replay
    # it as one batched draw instead of per-cell Ruby calls. Called only
    # when @model.generation advances (i.e. iterate ran), and we also lazily
    # skip the costly entropy overlay unless the user has toggled it on.
    def rebuild_map_macro
      model = @model
      width = model.width
      height = model.height
      tw = @tile_width
      th = @tile_height
      tiles = @tiles
      show_entropy = @show_entropy
      max_entropy = model.max_entropy.to_f
      small_font = @small_font
      entropy_colors = @entropy_colors

      @map_macro = record(WIDTH, HEIGHT) do
        x = 0
        while x < width
          screen_x = x * tw
          y = 0
          while y < height
            screen_y = (height - 1 - y) * th

            tile_id = model.tile_id_at(x, y)
            if tile_id
              tiles[tile_id].draw(screen_x, screen_y, 0)
            elsif show_entropy
              entropy = model.entropy_at(x, y)
              if entropy > 1
                percent_entropy = (entropy / max_entropy * 255).to_i
                percent_entropy = 255 if percent_entropy > 255
                percent_entropy = 0 if percent_entropy < 0
                small_font.draw_text_rel(
                  entropy,
                  screen_x + (tw / 2),
                  screen_y + (th / 2),
                  0, 0.5, 0.5, 1, 1, entropy_colors[percent_entropy]
                )
              end
            end
            y += 1
          end
          x += 1
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
