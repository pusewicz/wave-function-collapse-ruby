# frozen_string_literal: true

require "test_helper"

class TestTile < Minitest::Test
  def test_intern_edge_does_not_collide_for_wide_wang_ids
    # Earlier the cache key was packed as `(a << 16) | (b << 8) | c`, which
    # silently collided once any component exceeded 255. Regression: the
    # interning cache must distinguish triples with components ≥ 256.
    e1 = Tile.intern_edge(1, 0, 256)
    e2 = Tile.intern_edge(1, 1, 0)
    assert_equal [1, 0, 256], e1
    assert_equal [1, 1, 0], e2
    refute_equal e1, e2
  end

  def test_intern_edge_returns_same_object_for_equal_triples
    e1 = Tile.intern_edge(3, 4, 5)
    e2 = Tile.intern_edge(3, 4, 5)
    assert_same e1, e2
  end
end
