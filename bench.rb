require "benchmark/ips"

class TestA
  attr_reader :x, :y

  def initialize(x, y)
    @x = 0
    @y = 0
    @tiles  = 180.times.map { |i| i }
    @neighbors = { up: 1, down: 2, right: 3, left: 4 }
  end
end

class TestB < TestA
  def ==(other)
    @x == other.x && @y == other.y
  end
end

objects_a = 16.times.map { |x| 120.times.map { |y| TestA.new(x, y) } }.flatten
objects_b = 16.times.map { |x| 120.times.map { |y| TestB.new(x, y) } }.flatten

test_a = objects_a[1000]
test_b = objects_b[1000]

Benchmark.ips do |x|
  x.report("test_a") { |times|
    i = 0
    while i < times
      objects_a.delete(objects_a[times])
      i += 1
    end
  }
  x.report("test_b") { |times|
    i = 0
    while i < times
      objects_b.delete(objects_b[times])
      i += 1
    end
  }

  x.compare!
end
