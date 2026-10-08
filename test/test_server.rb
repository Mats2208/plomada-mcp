# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/fakes'
require 'plomada/server'

# The pump, driven tick by tick against fakes: framing, hello and auth, the
# queue, cancel, transparent operation chaining, deadlines and model changes.
class TestServer < Minitest::Test
  TOKEN = 'a' * 64

  # A job that adds one entity per step; it can be told to fail at a step.
  class AddJob < Plomada::Job
    def initialize(model, steps, fail_at: nil)
      super('Plomada: test build', steps)
      @model_ref = model
      @steps = steps
      @fail_at = fail_at
      @done = 0
    end

    def step(_budget)
      @done += 1
      @model_ref.entities.add
      raise ArgumentError, 'boom' if @fail_at == @done

      { done: @done >= @steps, progress: @done, total: @steps, message: "unit #{@done}",
        result: @done >= @steps ? { 'built' => @done } : nil }
    end
  end

  def setup
    @clock = Fakes::Clock.new
    @sched = Fakes::Scheduler.new
    @listener = Fakes::Listener.new
    @model = Fakes::Model.new
    @audit = Fakes::Audit.new
    @allow_ruby = false
    @server = build_server(Plomada::CONFIG)
  end

  def build_server(config)
    registry = Plomada::Registry.new
    registry.read('echo') { |params, _ctx| params }
    registry.read('slow') do |_p, _c|
      @clock.advance(20)
      { 'slow' => true }
    end
    registry.read('capture_view', exclusive: true) { |_p, _c| { 'image' => true } }
    registry.job('build') do |params, ctx|
      raise Plomada::InvalidParams, 'steps must be greater than 0, got 0' if params['steps']&.zero?

      AddJob.new(ctx.model, params.fetch('steps', 3), fail_at: params['fail_at'])
    end
    registry.job('execute_ruby') { |_p, ctx| AddJob.new(ctx.model, 1) }
    server = Plomada::Server.new(
      registry: registry, token: TOKEN, config: config,
      deps: {
        clock: @clock, listen: ->(_h, _p) { @listener }, scheduler: @sched,
        model: -> { @model }, undo: ->(m) { m.undo }, audit: @audit, log: ->(_m) {},
        capabilities: { 'pro' => true, 'entities_build' => true, 'pbr' => true, 'fbx_export' => true },
        allow_ruby: -> { @allow_ruby }
      }
    )
    server.start
  end

  def connect(token: TOKEN, protocol: 1)
    sock = @listener.connect(Fakes::Socket.new)
    sock.send_request({ 'jsonrpc' => '2.0', 'id' => 0, 'method' => 'hello',
                        'params' => { 'protocol' => protocol, 'client_version' => '0.1.0', 'token' => token } })
    @server.tick
    sock
  end

  def request(sock, id, method, params = {}, deadline_ms: nil)
    msg = { 'jsonrpc' => '2.0', 'id' => id, 'method' => method, 'params' => params }
    msg['deadline_ms'] = deadline_ms if deadline_ms
    sock.send_request(msg)
  end

  def ticks(n = 1) = n.times { @server.tick }

  # --- framing ------------------------------------------------------------------------

  def test_reader_waits_for_partial_frames_and_splits_two_in_one_read
    frame_a = Plomada::Framing.encode({ 'a' => 1 }, 1024)
    frame_b = Plomada::Framing.encode({ 'b' => 'ñ' }, 1024)
    reader = Plomada::Framing::Reader.new(1024)
    reader.feed(frame_a.byteslice(0, 2))
    assert_nil reader.next_frame, 'header incomplete'
    reader.feed(frame_a.byteslice(2, 5))
    assert_nil reader.next_frame, 'body incomplete'
    reader.feed(frame_a.byteslice(7..) + frame_b)
    assert_equal({ 'a' => 1 }, JSON.parse(reader.next_frame))
    assert_equal({ 'b' => 'ñ' }, JSON.parse(reader.next_frame))
    assert_nil reader.next_frame
  end

  def test_partial_frames_over_the_socket
    sock = @listener.connect(Fakes::Socket.new(read_limit: 3))
    sock.send_request({ 'jsonrpc' => '2.0', 'id' => 0, 'method' => 'hello',
                        'params' => { 'protocol' => 1, 'client_version' => 't', 'token' => TOKEN } })
    request(sock, 1, 'echo', { 'x' => 1 })
    ticks(20)
    assert sock.response(0)['result']
    assert_equal({ 'x' => 1 }, sock.response(1)['result'])
  end

  def test_oversized_frame_closes_the_connection
    sock = connect
    sock.deliver([Plomada::CONFIG[:max_frame_bytes] + 1].pack('N'))
    ticks(2)
    assert sock.closed?
    err = sock.responses.last['error']
    assert_equal(-32_002, err['code'])
    assert_match(/exceeds the 33554432-byte limit/, err['message'])
    assert_empty @server.clients
  end

  # --- hello and auth -----------------------------------------------------------------

  def test_hello_returns_capabilities_and_client_id
    sock = connect
    res = sock.response(0)['result']
    assert_equal Plomada::VERSION, res['server_version']
    assert_equal 1, res['protocol']
    assert_equal({ 'pro' => true, 'entities_build' => true, 'pbr' => true, 'fbx_export' => true }, res['capabilities'])
    assert_equal 'c1', res['client_id']
    refute sock.closed?
  end

  def test_wrong_protocol_is_refused_and_closed
    sock = connect(protocol: 2)
    ticks
    assert_equal(-32_002, sock.response(0)['error']['code'])
    assert sock.closed?
  end

  def test_wrong_or_missing_token_is_refused_and_closed
    [('b' * 64), nil, 'a' * 63].each do |tok|
      sock = connect(token: tok)
      ticks
      assert_equal(-32_001, sock.response(0)['error']['code'], "token #{tok.inspect}")
      assert sock.closed?
    end
  end

  def test_first_frame_must_be_hello
    sock = @listener.connect(Fakes::Socket.new)
    request(sock, 7, 'status')
    ticks(2)
    assert_equal(-32_002, sock.response(7)['error']['code'])
    assert sock.closed?
  end

  def test_silent_socket_is_closed_after_the_hello_timeout
    sock = @listener.connect(Fakes::Socket.new)
    ticks
    @clock.advance(9_999)
    ticks
    refute sock.closed?
    @clock.advance(2)
    ticks(2)
    assert sock.closed?
  end

  def test_secure_compare
    assert Plomada::Auth.secure_compare('a' * 64, 'a' * 64)
    refute Plomada::Auth.secure_compare('a' * 64, "#{'a' * 63}b")
    refute Plomada::Auth.secure_compare('a' * 63, 'a' * 64)
    refute Plomada::Auth.secure_compare(nil, 'a' * 64)
    refute Plomada::Auth.secure_compare(64, 'a' * 64)
  end

  def test_too_many_clients
    8.times { connect }
    extra = connect
    ticks
    assert extra.closed?
    assert_equal(-32_006, extra.frames.last['error']['code'])
    assert_equal 8, @server.clients.size
  end

  # --- queue ----------------------------------------------------------------------------

  def test_queue_overflow_replies_queue_full
    assert_equal 256, Plomada::CONFIG[:queue_cap]
    @server.stop
    @server = build_server(Plomada::CONFIG.merge(queue_cap: 3))
    sock = connect
    (1..6).each { |i| request(sock, i, 'build', { 'steps' => 50 }) }
    ticks
    # All six arrive in one read phase: three fit, three overflow; then the
    # first job leaves the queue to run.
    (4..6).each { |i| assert_equal(-32_006, sock.response(i)['error']['code']) }
    assert_match(/queue full: 3 requests are waiting/, sock.response(6)['error']['message'])
    assert_equal 2, @server.queue.size
    assert_equal 'j1', @server.active_job.id
  end

  def test_unknown_method_and_bad_params
    sock = connect
    request(sock, 1, 'nope')
    sock.send_request({ 'jsonrpc' => '2.0', 'id' => 2, 'method' => 'echo', 'params' => [1] })
    ticks
    assert_equal(-32_601, sock.response(1)['error']['code'])
    assert_equal(-32_004, sock.response(2)['error']['code'])
  end

  def test_execute_ruby_refused_until_enabled
    sock = connect
    request(sock, 1, 'execute_ruby', { 'code' => '1+1' })
    ticks
    err = sock.response(1)['error']
    assert_equal(-32_010, err['code'])
    assert_match(/Extensions > Plomada > Settings/, err['message'])
    @allow_ruby = true
    request(sock, 2, 'execute_ruby', { 'code' => '1+1' })
    ticks(2)
    assert sock.response(2)['result']
  end

  # --- jobs: transparent chaining, progress, one undo -------------------------------------

  def test_job_steps_chain_transparent_operations
    sock = connect
    request(sock, 1, 'build', { 'steps' => 3 })
    ticks(4)
    res = sock.response(1)['result']
    assert_equal 3, res['built']
    assert_equal 'j1', res['job_id']
    assert_equal 3, res['steps']
    starts = @model.events.select { |e| e[0] == :start }
    assert_equal [:start, 'Plomada: test build', true, false, false], starts[0]
    assert_equal [:start, 'Plomada: test build', true, false, true], starts[1]
    assert_equal [:start, 'Plomada: test build', true, false, true], starts[2]
    assert_equal 3, @model.events.count { |e| e[0] == :commit }
    assert_equal 3, @model.entities.size
    progress = sock.notifications.map { |n| [n['params']['progress'], n['params']['total']] }
    assert_equal [[1, 3], [2, 3], [3, 3]], progress
    assert_equal 1, sock.notifications.first['params']['id']
    assert_equal 'build', @audit.lines.last[:method]
    assert_equal 'ok', @audit.lines.last[:outcome]
    # The chain is one undo step.
    @model.undo
    assert_equal 0, @model.entities.size
  end

  def test_one_job_step_per_tick_and_reads_answer_between_steps
    builder = connect
    watcher = connect
    request(builder, 1, 'build', { 'steps' => 5 })
    ticks
    assert_equal 1, @model.entities.size
    request(watcher, 9, 'status')
    ticks
    st = watcher.response(9)['result']
    assert_equal 'j1', st['job']['job_id']
    assert_equal 2, @model.entities.size, 'the job advanced exactly one more step'
  end

  def test_step_exception_aborts_and_reverts_the_whole_chain
    sock = connect
    request(sock, 1, 'build', { 'steps' => 4, 'fail_at' => 3 })
    ticks(4)
    err = sock.response(1)['error']
    assert_equal(-32_005, err['code'])
    assert_equal 'ArgumentError: boom', err['message']
    assert_equal true, err['data']['reverted']
    assert_includes @model.events, [:abort]
    assert_includes @model.events, [:undo]
    assert_equal 0, @model.entities.size, 'the model is exactly as before'
  end

  def test_refused_start_operation_is_an_error
    @model.start_result = false
    sock = connect
    request(sock, 1, 'build', { 'steps' => 2 })
    ticks(2)
    assert_match(/refused to start the operation/, sock.response(1)['error']['message'])
  end

  def test_invalid_params_from_the_job_factory
    sock = connect
    request(sock, 1, 'build', { 'steps' => 0 })
    ticks
    err = sock.response(1)['error']
    assert_equal(-32_004, err['code'])
    assert_equal 'steps must be greater than 0, got 0', err['message']
  end

  # --- cancel and deadlines -----------------------------------------------------------------

  def test_cancel_a_queued_request
    sock = connect
    request(sock, 1, 'build', { 'steps' => 10 })
    request(sock, 2, 'build', { 'steps' => 10 })
    ticks
    request(sock, 3, 'cancel', { 'id' => 2 })
    ticks
    assert_equal(-32_003, sock.response(2)['error']['code'])
    assert_equal({ 'cancelled' => true, 'state' => 'queued', 'method' => 'build' }, sock.response(3)['result'])
  end

  def test_cancel_the_running_job_reverts_it
    sock = connect
    request(sock, 1, 'build', { 'steps' => 10 })
    ticks(3)
    assert_equal 3, @model.entities.size
    request(sock, 2, 'cancel', { 'id' => 1 })
    ticks(2)
    assert_equal 'running', sock.response(2)['result']['state']
    err = sock.response(1)['error']
    assert_equal(-32_003, err['code'])
    assert_match(/cancelled/, err['message'])
    assert_equal 0, @model.entities.size
  end

  def test_deadline_aborts_and_restores_the_model
    sock = connect
    request(sock, 1, 'build', { 'steps' => 10 }, deadline_ms: 100)
    ticks(2)
    assert_equal 2, @model.entities.size
    @clock.advance(150)
    ticks
    err = sock.response(1)['error']
    assert_equal(-32_003, err['code'])
    assert_match(/expired: build passed its deadline after 2 steps/, err['message'])
    assert_equal 0, @model.entities.size
    assert_equal 1, @model.events.count { |e| e[0] == :undo }
  end

  def test_model_change_mid_job_is_reported_and_not_undone
    sock = connect
    request(sock, 1, 'build', { 'steps' => 10 })
    ticks(2)
    @model.entities.add # the user draws something between ticks
    ticks
    err = sock.response(1)['error']
    assert_equal(-32_007, err['code'])
    assert_equal false, err['data']['reverted']
    refute_includes @model.events, [:undo]
  end

  def test_expired_while_queued_never_runs
    sock = connect
    request(sock, 1, 'build', { 'steps' => 5 })
    request(sock, 2, 'build', { 'steps' => 1 }, deadline_ms: 50)
    ticks
    @clock.advance(60)
    ticks(6)
    assert_equal(-32_003, sock.response(2)['error']['code'])
    assert_equal 5, @model.entities.size
  end

  # --- budgets and the timer ------------------------------------------------------------------

  def test_read_budget_spills_over_to_the_next_tick
    sock = connect
    (1..3).each { |i| request(sock, i, 'slow') }
    ticks
    # 20 ms per read against a 15 ms budget: one read per tick.
    assert sock.response(1)
    assert_nil sock.response(2)
    ticks
    assert sock.response(2)
  end

  def test_exclusive_capture_runs_alone
    sock = connect
    request(sock, 1, 'build', { 'steps' => 3 })
    request(sock, 2, 'capture_view')
    ticks
    assert sock.response(2)
    assert_equal 0, @model.entities.size, 'no job step in the capture tick'
  end

  def test_tick_backs_off_when_idle_and_records_max_tick
    connect
    assert_equal 30, @sched.current_interval
    @clock.advance(1_500)
    ticks
    assert_equal 100, @sched.current_interval
    st = nil
    sock = connect
    request(sock, 5, 'status')
    ticks
    st = sock.response(5)['result']
    assert_kind_of Float, st['max_tick_ms']
    assert_equal 30, st['tick_interval_ms']
  end

  def test_reentrant_tick_is_ignored
    @server.instance_variable_set(:@in_tick, true)
    before = @server.ticks
    @server.tick
    assert_equal before, @server.ticks
  end
end
