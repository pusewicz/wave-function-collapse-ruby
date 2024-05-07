# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "wave_function_collapse"
require "debug"
require "minitest/autorun"

Minitest::Test.send(:include, WaveFunctionCollapse)
