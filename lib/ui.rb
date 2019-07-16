# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/streaming'
require 'thin'
require 'slim'
require 'json'

# rubocop:disable Documentation

module Rmk
  class BuildResult
    attr_accessor :depends

    def initialize(item)
      @item = item
      @depends = []
    end

    def name
      @item.name
    end

    def dir
      @item.plan.dir
    end

    def id
      @item.id
    end

    def exception
      @item.exception
    end
  end

  class RootBuildResult
    attr_accessor :depends
    attr_reader :build_results

    def initialize(controller, jobs)
      @controller = controller
      @build_results = {}
      @build_results['root'] = self
      @depends = scan(jobs)
    end

    def name
      @controller.task
    end

    def dir
      @controller.dir
    end

    def id
      'root'
    end

    def exception
      list = @depends.reject { |i| i.exception.nil? }
      list.empty? ? nil : list.first.exception
    end

    def scan(jobs)
      result = []
      jobs.each do |item|
        next unless item.is_a?(Rmk::Job)

        build_result = @build_results[item.id] ||= BuildResult.new(item)
        build_result.depends = scan(item.depends)
        result << build_result
      end
      result
    end
  end

  class SseLogger
    class Writer
      def initialize(channel, connections)
        @channel = channel
        @connections = connections
      end

      def write(data)
        # $stdout.write(data)
        event = { channel: @channel, data: data}
        @connections.each do |c|
          c << "data: #{event.to_json}\n\n" unless c.closed?
        end
      end
    end

    def initialize
      @connections = []
    end

    def writer(channel)
      Writer.new(channel, @connections)
    end

    def subscribe(out)
      @connections << out
      @connections.reject!(&:closed?)
    end
  end

  class App < Sinatra::Base
    helpers Sinatra::Streaming

    def initialize(controller, build_interval)
      super()
      @controller = controller
      @build_interval = build_interval
      @status_connections = []
      @sse_logger = SseLogger.new
      Rmk.stdout = @sse_logger.writer(:out)
      Rmk.stderr = @sse_logger.writer(:err)
      self.status = :idle
      @root_build_results = RootBuildResult.new(@controller, [])
      build
    end

    def build
      self.status = :building
      @controller.run do |jobs|
        @root_build_results = RootBuildResult.new(@controller, jobs)
        self.status = :finished
        EventMachine.add_timer(@build_interval) do
          build
        end
        self.status = :idle
      end
    end

    def status=(value)
      @status = value
      @status_connections.each do |c|
        c <<  c << "data: #{@status}\n\n" unless c.closed?
      end
    end

    def subscribe_status(out)
      @status_connections << out
      out << "data: #{@status}\n\n"
      # purge dead connections
      @status_connections.reject!(&:closed?)
    end

    configure do
      set :threaded, false
    end

    get '/' do
      redirect to('/build/root')
    end

    get '/build/:id' do
      @build_result = @root_build_results.build_results[params['id']]
      halt 404 unless @build_result
      slim :build
    end

    get '/favicon.ico' do
    end

    get '/status', provides: 'text/event-stream' do
      stream(:keep_open) do |out|
        subscribe_status(out)
      end
    end

    get '/log' do
      slim :log
    end

    get '/log/stream', provides: 'text/event-stream' do
      stream(:keep_open) do |out|
        @sse_logger.subscribe(out)
      end
    end

    def self.run(controller, build_interval)
      EventMachine.run do
        web_app = App.new(controller, build_interval)

        dispatch = Rack::Builder.app do
          map '/' do
            run web_app
          end
        end

        Rack::Server.start(app: dispatch, server: 'thin', Host: '0.0.0.0',
                           Port: '8181', signals: false)
      end
    end
  end
end
