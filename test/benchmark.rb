# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "benchmark"
require "json"
require "wave_function_collapse"

include WaveFunctionCollapse

json = JSON.load_file!("assets/map.tsj")
tiles =
  json["wangsets"].last["wangtiles"].map do |tile|
    prob = json["tiles"]&.find { |t| t["id"] == tile["tileid"] }&.fetch("probability")
    Tile.new(
      tileid: tile["tileid"],
      wangid: tile["wangid"],
      probability: prob
    )
  end

model = Model.new(tiles, 20, 20)

puts RUBY_DESCRIPTION
puts "Running benchmark for Model(grid=#{model.width}x#{model.height} entropy=#{model.max_entropy})..."

puts Benchmark.measure {
  until model.complete?
    model.solve
  end
}
