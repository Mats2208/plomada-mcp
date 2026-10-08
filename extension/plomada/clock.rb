# frozen_string_literal: true

module Plomada
  # Monotonic milliseconds; never the wall clock.
  module Clock
    def self.now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
  end
end
