# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require_relative 'version'
require_relative 'config'
require_relative 'errors'
require_relative 'clock'
require_relative 'security'
require_relative 'server'
require_relative 'handlers'
require_relative 'ui'

module Plomada
  # UI.start_timer behind the scheduler interface the pump expects.
  class TimerScheduler
    def start(ms, &blk) = UI.start_timer(ms / 1000.0, true, &blk)
    def stop(id) = UI.stop_timer(id)
  end

  # Owns the running server inside SketchUp.
  module App
    class << self
      attr_reader :server, :last_error, :token

      def settings = Settings.new(Sketchup)
      def audit = (@audit ||= Audit.new)

      def start
        return @server if @server&.running?

        @token = Auth.load_or_create_token
        s = settings
        registry = Handlers.install(Registry.new)
        @server = Server.new(
          registry: registry, token: @token,
          deps: {
            listen: ->(host, port) { TCPServer.new(host, port) },
            scheduler: TimerScheduler.new,
            model: -> { Sketchup.active_model },
            undo: ->(_model) { Sketchup.undo },
            audit: audit,
            log: ->(msg) { puts msg },
            capabilities: SU.capabilities,
            info: { 'sketchup_version' => Sketchup.version, 'ruby_version' => RUBY_VERSION,
                    'token_path' => Paths.token_path },
            allow_ruby: -> { Settings.new(Sketchup).allow_ruby? },
            port: s.port,
            tick_busy_ms: s.tick_ms
          }
        ).start
        write_endpoint(s.port)
        @last_error = nil
        s.warnings.each { |w| puts "[Plomada] #{w}" }
        puts "[Plomada] #{VERSION} listening on #{CONFIG[:host]}:#{s.port} (token in #{Paths.token_path})"
        @server
      rescue StandardError => e
        @server = nil
        @last_error = "#{e.class}: #{e.message}"
        puts "[Plomada] could not start: #{@last_error}"
        nil
      end

      def stop
        @server&.stop
        @server = nil
      end

      def restart
        stop
        start
      end

      def write_endpoint(port)
        info = { 'host' => CONFIG[:host], 'port' => port, 'protocol' => CONFIG[:protocol],
                 'server_version' => VERSION, 'pid' => Process.pid }
        Auth.write_atomically(Paths.endpoint_path, JSON.generate(info))
      rescue SystemCallError => e
        puts "[Plomada] could not write #{Paths.endpoint_path}: #{e.message}"
      end

      # Development helper: reload every file and restart the server.
      def reload!
        stop
        dir = __dir__
        verbose = $VERBOSE
        $VERBOSE = nil
        Dir.glob(File.join(dir, '**', '*.rb')).sort.each do |f|
          next if File.basename(f) == 'main.rb'

          load f
        end
        $VERBOSE = verbose
        start
      end
    end
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Extensions').add_submenu(EXTENSION_NAME)
    menu.add_item('Settings...') { SettingsDialog.show }
    menu.add_item('Restart server') { App.restart }
    file_loaded(__FILE__)
    App.start
  end
end
