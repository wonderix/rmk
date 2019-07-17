# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/streaming'
require 'thin'
require 'slim'
require 'json'
require 'ostruct'

# rubocop:disable Documentation

module Rmk
  class BuildResult
    attr_accessor :depends

    def initialize(job)
      @job = job
      @depends = []
    end

    def jobs
      [@job]
    end

    def name
      @job.name
    end

    def dir
      @job.plan.dir
    end

    def id
      @job.id
    end

    def exception
      @job.exception
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

    def jobs
      nil
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
      jobs.each do |job|
        next unless job.is_a?(Rmk::Job)

        build_result = @build_results[job.id] ||= BuildResult.new(job)
        build_result.depends = scan(job.depends)
        result << build_result
      end
      result
    end
  end

  class SseLogger
    class Writer
      def initialize(channel, connections, logs)
        @channel = channel
        @connections = connections
        @logs = logs
      end

      def write(data)
        # $stdout.write(data)
        log = { channel: @channel, data: data,
                time: Time.now.strftime('%H:%M:%S') }
        @logs.shift if @logs.size > 1000
        @logs << log
        @connections.each do |c|
          c << "data: #{log.to_json}\n\n" unless c.closed?
        end
      end
    end

    attr_reader :logs
    def initialize
      @connections = []
      @logs = []
    end

    def writer(channel)
      Writer.new(channel, @connections, @logs)
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
      @status_connections = []
      @sse_logger = SseLogger.new
      Rmk.stdout = @sse_logger.writer(:out)
      Rmk.stderr = @sse_logger.writer(:error)
      self.status = :idle
      @root_build_results = RootBuildResult.new(@controller, [])
      @queue = EventMachine::Queue.new
      build(interval: build_interval)
    end

    def build(policy: nil, interval: nil, jobs: nil)
      self.status = :building
      @controller.run(policy: policy, jobs: jobs) do |result_jobs|
        @root_build_results = RootBuildResult.new(@controller, result_jobs)
        self.status = :finished
        if interval
          EventMachine.add_timer(interval) do
            @queue.push({ policy: policy, interval: interval, jobs: jobs }) # rubocop:disable Style/BracesAroundHashParameters, Metrics/LineLength
            @queue.pop do |options|
              build(**options)
            end
          end
        end
        self.status = :idle
      end
    end

    def status=(value)
      @status = value
      @status_connections.each do |c|
        c << "data: #{@status}\n\n" unless c.closed?
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
      @logs = @sse_logger.logs
      halt 404 unless @build_result
      slim :build
    end

    get '/rebuild/:id' do
      @build_result = @root_build_results.build_results[params['id']]
      halt 404 unless @build_result
      @queue.push({ policy: LocalBuildPolicy.new, jobs: @build_result.jobs }) # rubocop:disable Style/BracesAroundHashParameters, Metrics/LineLength
      @queue.pop do |options|
        build(**options)
      end
      redirect to("/build/#{params['id']}")
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
