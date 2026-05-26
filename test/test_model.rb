# frozen_string_literal: true

require "test_helper"

class TestModel < Minitest::Test
  def test_initialize
    tiles = [
      Tile.new(tileid: 0, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 1, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 2, wangid: [0, 0, 0, 0, 0, 0, 0, 0])
    ]
    model = Model.new(tiles, 320, 240)

    assert_equal 320, model.width
    assert_equal 240, model.height
    assert_equal 3, model.max_entropy
    assert_equal 0.0, model.percent
    refute model.complete?
    assert model.solve
    assert model.iterate
  end

  def test_prepend_empty_row
    tiles = [
      Tile.new(tileid: 0, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 1, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 2, wangid: [0, 0, 0, 0, 0, 0, 0, 0])
    ]
    model = Model.new(tiles, 2, 2)
    model.solve
    model.iterate
    model.iterate
    model.iterate

    assert model.complete?

    model.prepend_empty_row

    assert_equal 1, model.entropy_at(0, 0)
    assert_equal 1, model.entropy_at(1, 0)
    assert_equal 3, model.entropy_at(0, 1)
    assert_equal 3, model.entropy_at(1, 1)

    assert_equal 2, model.width
    assert_equal 2, model.height
    assert_equal 3, model.max_entropy
    assert_equal 50.0, model.percent
  end

  def test_prepend_empty_row_3x3
    tiles = [
      Tile.new(tileid: 0, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 1, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 2, wangid: [0, 0, 0, 0, 0, 0, 0, 0])
    ]
    model = Model.new(tiles, 3, 3)
    model.iterate until model.complete?
    assert model.complete?

    model.prepend_empty_row

    # Bottom two rows were the bottom two of the prior 3x3 (collapsed).
    # Top row is the freshly-inserted empty row (entropy == max_entropy == 3).
    assert_equal 1, model.entropy_at(0, 0)
    assert_equal 1, model.entropy_at(1, 0)
    assert_equal 1, model.entropy_at(2, 0)
    assert_equal 1, model.entropy_at(0, 1)
    assert_equal 1, model.entropy_at(1, 1)
    assert_equal 1, model.entropy_at(2, 1)
    assert_equal 3, model.entropy_at(0, 2)
    assert_equal 3, model.entropy_at(1, 2)
    assert_equal 3, model.entropy_at(2, 2)
  end

  def test_zero_probability_tile_does_not_poison_entropy
    # `w * Math.log(w)` is NaN for w == 0; if that leaks into the entropy
    # table, `find_lowest_entropy_cell` never picks a cell and the solve
    # loop spins forever. Regression for the bug found by /pr-bug-hunt.
    tiles = [
      Tile.new(tileid: 0, wangid: [0, 0, 0, 0, 0, 0, 0, 0], probability: 1.0),
      Tile.new(tileid: 1, wangid: [0, 0, 0, 0, 0, 0, 0, 0], probability: 0.0)
    ]
    model = Model.new(tiles, 2, 2)
    model.iterate until model.complete?
    assert model.complete?
    model.grid.each { |col| col.each { |t| refute_nil t } }
  end
end
