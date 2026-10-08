# frozen_string_literal: true

require 'json'
require 'socket'
require_relative 'config'
require_relative 'errors'
require_relative 'framing'
require_relative 'security'
require_relative 'jobs'
require_relative 'version'
require_relative 'clock'

module Plomada
  # Method table. A :read handler answers in the tick it is dequeued
  # (impl.call(params, ctx) -> result); a :job handler returns a Job that the
  # pump advances one step per tick (impl.call(params, ctx) -> Job). An
  # exclusive read (a viewport capture) runs alone in its tick.
  class Registry
    Handler = Struct.new(:name, :kind, :exclusive, :impl, keyword_init: true)

    def initialize
      @handlers = {}
    end

    def read(name, exclusive: false, &impl)
      @handlers[name] = Handler.new(name: name, kind: :read, exclusive: exclusive, impl: impl)
    end

    def job(name, &impl)
      @handlers[name] = Handler.new(name: name, kind: :job, exclusive: false, impl: impl)
    end

    def [](name) = @handlers[name]
    def names = @handlers.keys
  end

  Ctx = Struct.new(:server, :client_id, :request_id, :model, keyword_init: true)

  # The pump. Everything runs inside one repeating UI timer on SketchUp's
  # main thread: no Ruby threads, no blocking calls. Each tick, in order:
  # accept new connections, read frames, enqueue requests, answer read-only
  # requests within a budget, advance at most one mutating job by one step,
  # flush writes. The tick interval is short while there is work and backs
  # off when idle.
  class Server
    LOOPBACK = %w[127.0.0.1 ::1].freeze

    Client = Struct.new(:id, :socket, :reader, :out, :authed, :opened_at, :closing, :closed,
                        keyword_init: true)
    Request = Struct.new(:client, :id, :method, :params, :handler, :received_at, :deadline_at,
                         keyword_init: true)

    attr_reader :clients, :queue, :active_job, :finished, :config, :registry, :port,
                :max_tick_ms, :last_tick_ms, :ticks, :interval_ms, :listener

    # deps: clock (now_ms), listen (->(host, port) -> listener), scheduler
    # (start(ms) { } -> id, stop(id)), model (-> current model), undo
    # (->(model) reverts the last operation), audit (#record), log (->(msg)),
    # capabilities (Hash), info (Hash: sketchup_version, ruby_version),
    # allow_ruby (-> bool), port, tick_busy_ms.
    def initialize(registry:, token:, deps:, config: CONFIG)
      @registry = registry
      @token = token
      @cfg = config
      @clock = deps.fetch(:clock, Clock)
      @listen = deps.fetch(:listen)
      @scheduler = deps.fetch(:scheduler)
      @model = deps.fetch(:model)
      @undo = deps.fetch(:undo)
      @audit = deps.fetch(:audit)
      @log = deps.fetch(:log, ->(msg) { warn(msg) })
      @capabilities = deps.fetch(:capabilities, {})
      @info = deps.fetch(:info, {})
      @allow_ruby = deps.fetch(:allow_ruby, -> { false })
      @mark = deps.fetch(:mark, ->(_model, _job) {})
      @port = deps.fetch(:port, config[:port])
      @busy_ms = deps.fetch(:tick_busy_ms, config[:tick_busy_ms])
      @idle_ms = [config[:tick_idle_ms], @busy_ms].max
      @clients = []
      @queue = []
      @finished = []
      @active_job = nil
      @client_seq = 0
      @job_seq = 0
      @in_tick = false
      @max_tick_ms = 0.0
      @max_tick_what = 'idle'
      @tick_what = []
      @last_tick_ms = 0.0
      @ticks = 0
      @timer = nil
      @interval_ms = nil
      @last_activity = -Float::INFINITY
      register_builtins
    end

    # --- lifecycle --------------------------------------------------------------

    def start
      host = @cfg[:host]
      unless LOOPBACK.include?(host)
        raise Error.new(Codes::PROTOCOL, "refusing to listen on #{host.inspect}: Plomada binds only to a loopback literal (127.0.0.1 or ::1)")
      end

      @listener = @listen.call(host, @port)
      @started_at = @clock.now_ms
      schedule(@idle_ms)
      self
    end

    def stop
      @scheduler.stop(@timer) if @timer
      @timer = nil
      @clients.dup.each { |c| close_client(c) }
      @listener&.close
      @listener = nil
    end

    def running? = !@listener.nil?

    def reset_max_tick!
      @max_tick_ms = 0.0
      @max_tick_what = 'idle'
    end

    # --- the tick -----------------------------------------------------------------

    def tick
      return if @in_tick # a modal dialog opened inside a handler pumps timers too

      @in_tick = true
      @tick_what = []
      t0 = @clock.now_ms
      begin
        accept_clients(t0)
        @clients.dup.each { |c| read_client(c, t0) }
        expire_handshakes(t0)
        exclusive = run_reads(t0)
        advance_job unless exclusive
        @clients.dup.each { |c| flush(c) }
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise if e.is_a?(NoMemoryError) || e.is_a?(SignalException)

        @log.call("[Plomada] tick error #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      ensure
        dt = @clock.now_ms - t0
        @last_tick_ms = dt
        if dt > @max_tick_ms
          @max_tick_ms = dt
          @max_tick_what = @tick_what.empty? ? 'io' : @tick_what.join(', ')
        end
        @ticks += 1
        @in_tick = false
      end
      adapt_interval
    end

    # --- connections ----------------------------------------------------------------

    def accept_clients(now)
      return unless @listener

      @cfg[:max_accepts_per_tick].times do
        sock = @listener.accept_nonblock(exception: false)
        break if sock == :wait_readable || sock.nil?

        begin
          sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) if sock.respond_to?(:setsockopt)
        rescue StandardError
          nil
        end
        if @clients.size >= @cfg[:max_clients]
          refuse(sock, Codes::QUEUE_FULL, "too many clients: Plomada serves #{@cfg[:max_clients]} at once")
          next
        end
        @client_seq += 1
        @clients << Client.new(id: "c#{@client_seq}", socket: sock, reader: Framing::Reader.new(@cfg[:max_frame_bytes]),
                               out: String.new(encoding: Encoding::BINARY), authed: false, opened_at: now,
                               closing: false, closed: false)
        touch(now)
      end
    end

    def refuse(sock, code, message)
      frame = Framing.encode({ 'jsonrpc' => '2.0', 'id' => nil, 'error' => { 'code' => code, 'message' => message } },
                             @cfg[:max_frame_bytes])
      sock.write_nonblock(frame, exception: false)
    rescue StandardError
      nil
    ensure
      begin
        sock.close
      rescue StandardError
        nil
      end
    end

    def read_client(client, now)
      return if client.closed || client.closing

      frames = 0
      reads = 0
      while frames < @cfg[:max_frames_per_client_per_tick]
        body = begin
          client.reader.next_frame
        rescue Framing::FrameTooLarge, Error => e
          reply_error(client, nil, e)
          client.closing = true
          return
        end
        if body
          frames += 1
          touch(now)
          handle_frame(client, body, now)
          return if client.closed || client.closing

          next
        end
        break if reads >= @cfg[:max_reads_per_client_per_tick]

        reads += 1
        chunk = begin
          client.socket.read_nonblock(@cfg[:read_chunk_bytes], exception: false)
        rescue IOError, SystemCallError
          nil
        end
        break if chunk == :wait_readable

        if chunk.nil?
          close_client(client)
          return
        end
        client.reader.feed(chunk)
      end
    end

    def expire_handshakes(now)
      @clients.dup.each do |c|
        next if c.authed || c.closing || c.closed
        next if now - c.opened_at < @cfg[:hello_timeout_ms]

        reply_error(c, nil, Error.new(Codes::PROTOCOL, "no hello within #{@cfg[:hello_timeout_ms] / 1000} s; closing"))
        c.closing = true
      end
    end

    def handle_frame(client, body, now)
      msg = begin
        JSON.parse(body)
      rescue JSON::ParserError => e
        reply_error(client, nil, Error.new(Codes::PARSE_ERROR, "frame is not JSON: #{e.message[0, 120]}"))
        client.closing = true unless client.authed
        return
      end
      unless msg.is_a?(Hash) && msg['method'].is_a?(String) && msg.key?('id') && !msg['id'].nil?
        reply_error(client, msg.is_a?(Hash) ? msg['id'] : nil,
                    Error.new(Codes::INVALID_REQUEST, 'a request needs id, method and params'))
        client.closing = true unless client.authed
        return
      end
      return hello(client, msg) unless client.authed

      enqueue(client, msg, now)
    end

    def hello(client, msg)
      if msg['method'] != 'hello'
        reply_error(client, msg['id'], Error.new(Codes::PROTOCOL, "the first frame must be hello, got #{msg['method'].inspect}"))
        client.closing = true
        return
      end
      params = msg['params'].is_a?(Hash) ? msg['params'] : {}
      if params['protocol'] != @cfg[:protocol]
        reply_error(client, msg['id'], Error.new(Codes::PROTOCOL,
                                                 "protocol #{params['protocol'].inspect} is not supported; this extension speaks protocol #{@cfg[:protocol]} (Plomada #{VERSION})"))
        client.closing = true
        return
      end
      unless Auth.secure_compare(params['token'], @token)
        reply_error(client, msg['id'], Error.new(Codes::AUTH, 'token rejected: read it from the bridge.token file the extension wrote'))
        client.closing = true
        return
      end
      client.authed = true
      reply(client, msg['id'], {
              'server_version' => VERSION, 'protocol' => @cfg[:protocol],
              'capabilities' => @capabilities, 'client_id' => client.id
            })
    end

    # --- queue ------------------------------------------------------------------------

    def enqueue(client, msg, now)
      method = msg['method']
      params = msg['params'].nil? ? {} : msg['params']
      unless params.is_a?(Hash)
        return reply_error(client, msg['id'], InvalidParams.new("params must be an object, got #{params.class.name.downcase}"))
      end

      return cancel(client, msg['id'], params) if method == 'cancel'

      handler = @registry[method]
      unless handler
        return reply_error(client, msg['id'], Error.new(Codes::METHOD_NOT_FOUND, "unknown method #{method.inspect}"))
      end
      if method == 'execute_ruby' && !@allow_ruby.call
        return reply_error(client, msg['id'], Error.new(Codes::RUBY_DISABLED,
                                                        'execute_ruby is disabled; enable it in Extensions > Plomada > Settings'))
      end
      if @queue.size >= @cfg[:queue_cap]
        return reply_error(client, msg['id'], Error.new(Codes::QUEUE_FULL, "queue full: #{@cfg[:queue_cap]} requests are waiting"))
      end

      deadline_ms = msg['deadline_ms']
      deadline_ms = @cfg[:default_deadline_ms] unless deadline_ms.is_a?(Numeric) && deadline_ms.positive?
      @queue << Request.new(client: client, id: msg['id'], method: method, params: params, handler: handler,
                            received_at: now, deadline_at: now + deadline_ms)
    end

    # Cancels by request id (of the same client) or by job_id; with neither,
    # the running job. A queued request is dropped and answered -32003; the
    # running job finishes its current step, aborts and reports cancelled.
    def cancel(client, id, params)
      target = params['id']
      job_id = params['job_id']
      queued = target && @queue.find { |r| r.client.equal?(client) && r.id == target }
      if queued
        @queue.delete(queued)
        reply_error(queued.client, queued.id, Error.new(Codes::CANCELLED, "cancelled: #{queued.method} was dropped from the queue before it ran"))
        return reply(client, id, { 'cancelled' => true, 'state' => 'queued', 'method' => queued.method })
      end
      job = @active_job
      hit = job && ((target && job.request.client.equal?(client) && job.request.id == target) ||
                    (job_id && job.id == job_id) || (target.nil? && job_id.nil?))
      if hit
        job.cancel_requested = true
        return reply(client, id, { 'cancelled' => true, 'state' => 'running', 'job_id' => job.id, 'method' => job.request.method })
      end
      reply(client, id, { 'cancelled' => false, 'state' => 'not_found' })
    end

    # Answers read-only requests in FIFO order until the budget is spent.
    # Returns true when an exclusive read ran (no job step this tick then).
    def run_reads(t0)
      budget_end = t0 + @cfg[:readonly_budget_ms]
      ran = 0
      i = 0
      while i < @queue.size
        req = @queue[i]
        if req.handler.kind != :read
          i += 1
          next
        end
        now = @clock.now_ms
        break if ran.positive? && now >= budget_end
        return false if req.handler.exclusive && ran.positive?

        @queue.delete_at(i)
        next if req.client.closed

        if now > req.deadline_at
          reply_error(req.client, req.id, Error.new(Codes::CANCELLED, "expired: #{req.method} waited past its deadline"))
          next
        end
        run_read(req)
        ran += 1
        return true if req.handler.exclusive
      end
      false
    end

    def run_read(req)
      @tick_what << "read #{req.method}"
      ctx = Ctx.new(server: self, client_id: req.client.id, request_id: req.id, model: @model.call)
      result = req.handler.impl.call(req.params, ctx)
      reply(req.client, req.id, result)
    rescue Error => e
      reply_error(req.client, req.id, e)
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise if e.is_a?(NoMemoryError) || e.is_a?(SignalException)

      reply_error(req.client, req.id, Error.new(Codes::SKETCHUP, "#{e.class}: #{e.message}"))
    end

    # --- jobs -----------------------------------------------------------------------

    def advance_job
      @active_job ||= start_next_job
      job = @active_job
      return unless job

      now = @clock.now_ms
      return abort_job(job, Error.new(Codes::CANCELLED, "cancelled: #{job.request.method} was cancelled by the client")) if job.cancel_requested
      if now > job.request.deadline_at
        return abort_job(job, Error.new(Codes::CANCELLED,
                                        "expired: #{job.request.method} passed its deadline after #{job.steps_run} steps"))
      end
      return model_changed(job) if job.committed_steps.positive? && !fingerprint_ok?(job)

      t0 = @clock.now_ms
      job.state = 'running'
      @tick_what << "#{job.request.method} step #{job.steps_run + 1}"
      result = begin
        if job.needs_operation?
          with_operation(job) { job.step(@cfg[:job_step_budget_ms]) }
        else
          job.step(@cfg[:job_step_budget_ms])
        end
      rescue Error => e
        return abort_job(job, e)
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise if e.is_a?(NoMemoryError) || e.is_a?(SignalException)

        return abort_job(job, Error.new(Codes::SKETCHUP, "#{e.class}: #{e.message}",
                                        { 'where' => e.backtrace&.first(3) }))
      end
      dt = @clock.now_ms - t0
      job.steps_run += 1
      job.max_step_ms = dt if dt > job.max_step_ms
      job.fingerprint = fingerprint(job.model)
      job.progress = result[:progress]
      job.message = result[:message]
      notify_progress(job)
      finish_job(job, result[:result]) if result[:done]
    end

    def start_next_job
      while (idx = @queue.index { |r| r.handler.kind == :job })
        req = @queue.delete_at(idx)
        next if req.client.closed

        now = @clock.now_ms
        if now > req.deadline_at
          reply_error(req.client, req.id, Error.new(Codes::CANCELLED, "expired: #{req.method} waited past its deadline"))
          next
        end
        model = @model.call
        ctx = Ctx.new(server: self, client_id: req.client.id, request_id: req.id, model: model)
        @tick_what << "prepare #{req.method}"
        begin
          job = req.handler.impl.call(req.params, ctx)
        rescue Error => e
          reply_error(req.client, req.id, e)
          audit(req, now, "error #{e.code}")
          next
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise if e.is_a?(NoMemoryError) || e.is_a?(SignalException)

          reply_error(req.client, req.id, Error.new(Codes::SKETCHUP, "#{e.class}: #{e.message}"))
          audit(req, now, 'error -32005')
          next
        end
        @job_seq += 1
        job.id = "j#{@job_seq}"
        job.request = req
        job.model = model
        job.started_at = now
        job.fingerprint = fingerprint(model)
        return job
      end
      nil
    end

    # Strict operation wrapper: the boolean from start_operation is checked,
    # the step commits on success and aborts on any exception. The first step
    # opens the operation; later ones use the transparent form that merges
    # into it, so a whole job is a single Ctrl+Z.
    #
    # SketchUp drops an operation that changed nothing, and a transparent
    # operation then merges into whatever entry is below it. So the first step
    # always stamps the job on the model (deps[:mark]); the chain then has a
    # base entry of its own even when the first unit had nothing to do.
    def with_operation(job)
      model = job.model
      first = job.committed_steps.zero?
      started = if first
                  model.start_operation(job.label, true)
                else
                  model.start_operation(job.label, true, false, true)
                end
      raise Error.new(Codes::SKETCHUP, "SketchUp refused to start the operation #{job.label.inspect}") unless started

      begin
        @mark.call(model, job) if first
        result = yield
      rescue Exception # rubocop:disable Lint/RescueException
        model.abort_operation
        raise
      end
      raise Error.new(Codes::SKETCHUP, "SketchUp refused to commit the operation #{job.label.inspect}") unless model.commit_operation

      job.committed_steps += 1
      result
    end

    def fingerprint(model)
      [model.guid, model.entities.size]
    rescue StandardError
      [nil, nil]
    end

    def fingerprint_ok?(job)
      current = @model.call
      current.equal?(job.model) && fingerprint(current) == job.fingerprint
    end

    # Reverts what the job committed (one transparent chain = one undo) as
    # long as nothing else touched the model, then reports the error.
    def abort_job(job, error)
      reverted = false
      if job.committed_steps.positive? && fingerprint_ok?(job)
        @undo.call(job.model)
        reverted = true
      end
      job.on_abort(error)
      data = (error.data || {}).merge('job_id' => job.id, 'steps_committed' => job.committed_steps,
                                      'reverted' => reverted || job.committed_steps.zero?)
      reply_error(job.request.client, job.request.id, Error.new(error.code, error.message, data))
      retire(job, "error #{error.code}")
    end

    def model_changed(job)
      err = Error.new(Codes::MODEL_CHANGED,
                      "the active model changed while #{job.request.method} was running (another model is active, " \
                      "or its top-level entities changed); stopped after #{job.committed_steps} steps. What was " \
                      "built stays as one undo step labelled #{job.label.inspect} in the model where it ran",
                      { 'job_id' => job.id, 'steps_committed' => job.committed_steps, 'reverted' => false })
      job.on_abort(err)
      reply_error(job.request.client, job.request.id, err)
      retire(job, 'error -32007')
    end

    def finish_job(job, result)
      payload = result.is_a?(Hash) ? result.dup : { 'result' => result }
      payload['job_id'] = job.id
      payload['steps'] = job.steps_run
      payload['elapsed_ms'] = (@clock.now_ms - job.started_at).round(1)
      payload['max_step_ms'] = job.max_step_ms.round(1)
      reply(job.request.client, job.request.id, payload)
      retire(job, 'ok')
    end

    def retire(job, outcome)
      job.state = outcome == 'ok' ? 'done' : outcome
      audit(job.request, job.started_at, outcome)
      @finished.unshift(job.summary.merge('outcome' => outcome,
                                          'elapsed_ms' => (@clock.now_ms - job.started_at).round(1)))
      @finished.pop while @finished.size > @cfg[:finished_jobs_kept]
      @active_job = nil
    end

    def audit(req, started, outcome)
      @audit.record(client_id: req.client.id, method: req.method, duration_ms: @clock.now_ms - started, outcome: outcome)
    end

    def notify_progress(job)
      send_frame(job.request.client, {
                   'jsonrpc' => '2.0', 'method' => 'progress',
                   'params' => { 'id' => job.request.id, 'job_id' => job.id, 'progress' => job.progress,
                                 'total' => job.total, 'message' => job.message }
                 })
    end

    # --- replies and writes -------------------------------------------------------------

    def reply(client, id, result)
      send_frame(client, { 'jsonrpc' => '2.0', 'id' => id, 'result' => result })
    end

    def reply_error(client, id, error)
      send_frame(client, { 'jsonrpc' => '2.0', 'id' => id, 'error' => error.to_rpc })
    end

    def send_frame(client, message)
      return if client.closed

      frame = begin
        Framing.encode(message, @cfg[:max_frame_bytes])
      rescue Framing::FrameTooLarge => e
        Framing.encode({ 'jsonrpc' => '2.0', 'id' => message['id'], 'error' => e.to_rpc }, @cfg[:max_frame_bytes])
      end
      if client.out.bytesize + frame.bytesize > @cfg[:max_pending_write_bytes]
        close_client(client)
        return
      end
      client.out << frame
    end

    def flush(client)
      return if client.closed

      until client.out.empty?
        n = begin
          client.socket.write_nonblock(client.out, exception: false)
        rescue IOError, SystemCallError
          close_client(client)
          return
        end
        break if n == :wait_writable

        client.out = client.out.byteslice(n, client.out.bytesize - n) || String.new(encoding: Encoding::BINARY)
      end
      close_client(client) if client.closing && client.out.empty?
    end

    def close_client(client)
      return if client.closed

      client.closed = true
      begin
        client.socket.close
      rescue StandardError
        nil
      end
      @clients.delete(client)
      @queue.reject! { |r| r.client.equal?(client) }
    end

    # --- timer --------------------------------------------------------------------------

    def touch(now)
      @last_activity = now
    end

    def busy?
      return true if @active_job || !@queue.empty?
      return true if @clients.any? { |c| !c.out.empty? || c.reader.frame_ready? }

      @clock.now_ms - @last_activity < @cfg[:idle_after_ms]
    end

    def adapt_interval
      return unless @listener

      want = busy? ? @busy_ms : @idle_ms
      schedule(want) if want != @interval_ms
    end

    def schedule(ms)
      @scheduler.stop(@timer) if @timer
      @interval_ms = ms
      @timer = @scheduler.start(ms) { tick }
    end

    # --- built-in methods ---------------------------------------------------------------

    def register_builtins
      @registry.read('status') { |params, ctx| status(params, ctx) }
      @registry.read('job_status') { |_params, _ctx| job_status }
      @registry.read('ping') { |_params, _ctx| { 'pong' => true } }
    end

    def status(params, ctx)
      job = @active_job&.summary
      job['elapsed_ms'] = (@clock.now_ms - @active_job.started_at).round(1) if job
      out = {
        'connected' => true, 'server_version' => VERSION, 'protocol' => @cfg[:protocol],
        'capabilities' => @capabilities, 'port' => @port, 'client_id' => ctx.client_id,
        'clients' => @clients.size, 'queue_length' => @queue.size, 'job' => job,
        'max_tick_ms' => @max_tick_ms.round(2), 'max_tick_what' => @max_tick_what,
        'last_tick_ms' => @last_tick_ms.round(2),
        'ticks' => @ticks, 'tick_interval_ms' => @interval_ms, 'allow_ruby' => @allow_ruby.call,
        'uptime_s' => ((@clock.now_ms - (@started_at || @clock.now_ms)) / 1000.0).round(1)
      }.merge(@info)
      reset_max_tick! if params['reset_max_tick'] == true
      out
    end

    def job_status
      job = @active_job&.summary
      job['elapsed_ms'] = (@clock.now_ms - @active_job.started_at).round(1) if job
      queued = @queue.select { |r| r.handler.kind == :job }.map { |r| { 'method' => r.method, 'client_id' => r.client.id } }
      { 'current' => job, 'queued' => queued, 'queue_length' => @queue.size, 'recent' => @finished.first(10) }
    end
  end
end
