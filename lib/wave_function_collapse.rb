# frozen_string_literal: true

module WaveFunctionCollapse
  class Error < StandardError; end

  autoload :Cell, "wave_function_collapse/cell"
  autoload :Model, "wave_function_collapse/model"
  autoload :Tile, "wave_function_collapse/tile"
  autoload :Window, "wave_function_collapse/window"
  autoload :ZOrder, "wave_function_collapse/z_order"
end
