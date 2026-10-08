# frozen_string_literal: true

module Plomada
  # Fixed JSON-RPC error codes shared with the Python bridge (plomada_bridge/errors.py).
  module Codes
    PARSE_ERROR      = -32_700 # malformed JSON in a frame
    INVALID_REQUEST  = -32_600 # frame is JSON but not a JSON-RPC request
    METHOD_NOT_FOUND = -32_601 # unknown method name
    AUTH             = -32_001 # wrong or missing token
    PROTOCOL         = -32_002 # wrong protocol, first frame not hello, oversized frame
    CANCELLED        = -32_003 # cancelled by the client or deadline expired
    INVALID_PARAMS   = -32_004 # params failed validation; message names the field path
    SKETCHUP         = -32_005 # SketchUp raised; message is the Ruby class and text
    QUEUE_FULL       = -32_006 # FIFO already holds CONFIG[:queue_cap] requests
    MODEL_CHANGED    = -32_007 # active model changed while a job was running
    RUBY_DISABLED    = -32_010 # execute_ruby is off in the settings
  end

  # An error that carries its JSON-RPC code. Everything the pump replies with
  # as an error is one of these; any other exception becomes Codes::SKETCHUP.
  class Error < StandardError
    attr_reader :code, :data

    def initialize(code, message, data = nil)
      super(message)
      @code = code
      @data = data
    end

    def to_rpc
      err = { 'code' => code, 'message' => message }
      err['data'] = data if data
      err
    end
  end

  # Params failed validation. The message starts with the field path,
  # for example "walls[2].thickness must be greater than 0, got -200".
  class InvalidParams < Error
    def initialize(message, data = nil)
      super(Codes::INVALID_PARAMS, message, data)
    end
  end
end
