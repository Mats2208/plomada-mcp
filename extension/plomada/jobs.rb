# frozen_string_literal: true

require_relative 'errors'

module Plomada
  # A mutating request runs as a Job: the pump calls step(budget_ms) once per
  # tick until it returns done. Each step is wrapped in one operation; the
  # first starts it and the rest chain onto it transparently, so the whole
  # job is one undo step however many ticks it takes.
  class Job
    attr_accessor :id, :request, :model, :committed_steps, :cancel_requested, :started_at,
                  :fingerprint, :progress, :message, :steps_run, :max_step_ms, :state
    attr_reader :label, :total

    def initialize(label, total = 1)
      @label = label
      @total = total
      @progress = 0
      @message = 'queued'
      @committed_steps = 0
      @steps_run = 0
      @max_step_ms = 0.0
      @cancel_requested = false
      @state = 'queued'
    end

    # Jobs that change the model run inside an operation; exports and undo do not.
    def needs_operation? = true

    # One small unit of work. Returns {done:, progress:, total:, message:, result:}.
    def step(_budget_ms)
      raise NotImplementedError
    end

    # Called after the job's operation was aborted and reverted.
    def on_abort(_error); end

    def summary
      {
        'job_id' => id, 'method' => request&.method, 'label' => label, 'state' => state,
        'progress' => progress, 'total' => total, 'message' => message,
        'client_id' => request&.client&.id, 'steps' => steps_run,
        'max_step_ms' => max_step_ms.round(1)
      }
    end
  end

  # A job made of named units run one per step, then a finisher that builds
  # the result. Units are lambdas; they share state through the job object.
  class UnitJob < Job
    def initialize(label, units, operation: true, &finisher)
      super(label, units.size)
      @units = units
      @index = 0
      @operation = operation
      @finisher = finisher
    end

    def needs_operation? = @operation

    def step(_budget_ms)
      name, work = @units[@index]
      work.call
      @index += 1
      done = @index >= @units.size
      { done: done, progress: @index, total: @units.size, message: name,
        result: done ? @finisher&.call : nil }
    end
  end
end
