# frozen_string_literal: true

require 'json'
require 'plomada/framing'

# Test doubles for the pump: no sockets, no SketchUp, no wall clock.
module Fakes
  class Clock
    attr_accessor :now

    def initialize(now = 1_000.0)
      @now = now
    end

    def now_ms = @now
    def advance(ms) = @now += ms
  end

  # Holds the one repeating timer the pump schedules; tests fire it by hand.
  class Scheduler
    attr_reader :intervals, :stopped

    def initialize
      @blocks = {}
      @seq = 0
      @intervals = []
      @stopped = []
    end

    def start(ms, &blk)
      @seq += 1
      @blocks[@seq] = blk
      @intervals << ms
      @seq
    end

    def stop(id)
      @stopped << id
      @blocks.delete(id)
    end

    def current_interval = @intervals.last
    def fire! = @blocks.values.last&.call
  end

  # A non-blocking socket double. Bytes queued with #deliver come out of
  # read_nonblock at most +read_limit+ at a time; writes are collected and can
  # be throttled with +write_limit+ to exercise partial writes.
  class Socket
    attr_reader :written, :options
    attr_accessor :read_limit, :write_limit, :eof

    def initialize(read_limit: 1 << 20, write_limit: 1 << 30)
      @inbox = String.new(encoding: Encoding::BINARY)
      @written = String.new(encoding: Encoding::BINARY)
      @read_limit = read_limit
      @write_limit = write_limit
      @closed = false
      @eof = false
      @options = []
    end

    def deliver(bytes)
      @inbox << bytes.b
      self
    end

    def send_request(obj) = deliver(Plomada::Framing.encode(obj, 64 << 20))

    def read_nonblock(max, exception: true)
      raise IOError, 'closed stream' if @closed
      return nil if @inbox.empty? && @eof
      return :wait_readable if @inbox.empty?

      n = [max, @read_limit, @inbox.bytesize].min
      chunk = @inbox.byteslice(0, n)
      @inbox = @inbox.byteslice(n, @inbox.bytesize - n)
      chunk
    end

    def write_nonblock(data, exception: true)
      raise IOError, 'closed stream' if @closed
      return :wait_writable if @write_limit.zero?

      n = [data.bytesize, @write_limit].min
      @written << data.byteslice(0, n)
      n
    end

    def setsockopt(*args) = @options << args
    def close = @closed = true
    def closed? = @closed

    # Every complete frame written so far, parsed.
    def frames
      reader = Plomada::Framing::Reader.new(64 << 20)
      reader.feed(@written)
      out = []
      while (body = reader.next_frame)
        out << JSON.parse(body)
      end
      out
    end

    def responses = frames.reject { |f| f.key?('method') }
    def notifications = frames.select { |f| f.key?('method') }
    def response(id) = responses.find { |f| f['id'] == id }
  end

  class Listener
    attr_reader :closed

    def initialize
      @pending = []
      @closed = false
    end

    def connect(socket)
      @pending << socket
      socket
    end

    def accept_nonblock(exception: true)
      @pending.empty? ? :wait_readable : @pending.shift
    end

    def close = @closed = true
  end

  class Entities
    include Enumerable

    def initialize
      @items = []
    end

    def add(item = Object.new)
      @items << item
      item
    end

    def size = @items.size
    def each(&) = @items.each(&)
    def snapshot = @items.dup
    def restore(items) = @items.replace(items)
  end

  # Records every operation call and keeps enough state to check that an
  # abort reverts the step and an undo reverts the transparent chain.
  class Model
    attr_reader :events, :entities
    attr_accessor :guid, :start_result, :commit_result

    def initialize
      @events = []
      @entities = Entities.new
      @guid = 'fake-guid-0001'
      @start_result = true
      @commit_result = true
      @open = nil
      @chain_base = nil
      @last_committed_base = nil
    end

    def start_operation(label, disable_ui = false, next_transparent = false, transparent = false)
      @events << [:start, label, disable_ui, next_transparent, transparent]
      return false unless @start_result

      @open = @entities.snapshot
      @chain_base = @open unless transparent
      true
    end

    def commit_operation
      @events << [:commit]
      @open = nil
      @last_committed_base = @chain_base
      @commit_result
    end

    def abort_operation
      @events << [:abort]
      @entities.restore(@open) if @open
      @open = nil
      true
    end

    # Sketchup.undo: reverts the last (possibly chained) operation.
    def undo
      @events << [:undo]
      @entities.restore(@last_committed_base) if @last_committed_base
      @last_committed_base = nil
    end
  end

  class View
    attr_accessor :camera, :written

    def initialize
      @written = []
      @camera = :original_camera
    end

    def write_image(opts)
      @written << opts
      true
    end
  end

  class Audit
    attr_reader :lines

    def initialize
      @lines = []
    end

    def record(**fields)
      @lines << fields
    end

    def tail(n) = @lines.last(n)
  end
end
