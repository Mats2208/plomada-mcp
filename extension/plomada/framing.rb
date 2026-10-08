# frozen_string_literal: true

require 'json'
require_relative 'errors'

module Plomada
  # Length-prefixed JSON-RPC frames: a 4-byte big-endian unsigned length, then
  # that many bytes of UTF-8 JSON.
  module Framing
    HEADER_BYTES = 4

    # A frame header announced more bytes than the cap; the connection closes.
    class FrameTooLarge < Error
      def initialize(size, max)
        super(Codes::PROTOCOL, "frame of #{size} bytes exceeds the #{max}-byte limit; closing the connection")
      end
    end

    module_function

    def encode(message, max_bytes)
      body = JSON.generate(message).b
      raise Error.new(Codes::INVALID_REQUEST, 'refusing to send an empty frame') if body.empty?
      raise FrameTooLarge.new(body.bytesize, max_bytes) if body.bytesize > max_bytes

      [body.bytesize].pack('N') + body
    end

    # Accumulates bytes and hands out complete frames one at a time, so a
    # partial frame waits for more bytes and two frames in one read come out
    # as two frames.
    class Reader
      def initialize(max_bytes)
        @max = max_bytes
        @buf = String.new(capacity: 4096, encoding: Encoding::BINARY)
        @pos = 0
      end

      def feed(bytes)
        @buf << bytes.b
        self
      end

      # The next complete frame body as a UTF-8 String, or nil when the
      # buffer does not hold one yet. Raises FrameTooLarge from the header
      # alone, before the oversized body arrives.
      def next_frame
        avail = @buf.bytesize - @pos
        return nil if avail < HEADER_BYTES

        size = @buf.byteslice(@pos, HEADER_BYTES).unpack1('N')
        raise FrameTooLarge.new(size, @max) if size > @max
        raise Error.new(Codes::INVALID_REQUEST, 'empty frame') if size.zero?
        return nil if avail < HEADER_BYTES + size

        body = @buf.byteslice(@pos + HEADER_BYTES, size)
        @pos += HEADER_BYTES + size
        compact
        body.force_encoding(Encoding::UTF_8)
      end

      def buffered_bytes = @buf.bytesize - @pos

      def frame_ready?
        avail = buffered_bytes
        return false if avail < HEADER_BYTES

        size = @buf.byteslice(@pos, HEADER_BYTES).unpack1('N')
        size > @max || avail >= HEADER_BYTES + size
      end

      private

      def compact
        return if @pos < 65_536 && @pos < @buf.bytesize

        @buf = @buf.byteslice(@pos, @buf.bytesize - @pos) || String.new(encoding: Encoding::BINARY)
        @pos = 0
      end
    end
  end
end
