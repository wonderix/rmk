# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/streaming'
require 'thin'
require 'slim'
require 'json'
require 'ostruct'

# rubocop:disable Documentation

class Graph
  attr_reader :nodes, :edges
  def initialize()
    @nodes = {}
    @edges = {}
  end
  def to_json
    obj = {}
    obj['nodes'] = @nodes
    obj['edges'] = @edges
    JSON.dump(obj)
  end
end

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

    def graph(gr)
      return if gr.nodes[id]

      gr.nodes[id] = { name: name, dir: dir, exception: exception }
      gr.edges[id] = depends.map(&:id)
      depends.each { |d| d.graph(gr) }
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

    def graph(gr)
      return if gr.nodes[id]

      gr.nodes[id] = { name: name, dir: dir, exception: exception }
      gr.edges[id] = depends.map(&:id)
      depends.each { |d| d.graph(gr) }
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
        data.split("\n").each do |message|
          next if message.empty?

          log = { channel: @channel, message: message,
                  time: Time.now.strftime('%H:%M:%S') }
          @logs.shift if @logs.size > 1000
          @logs << log
          @connections.each do |c|
            c << "data: #{log.to_json}\n\n" unless c.closed?
          end
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

  class Subscribable
    attr_reader :value
    def initialize(value)
      @value = value
      @connections = []
    end

    def value=(value)
      @value = value
      @connections.each do |c|
        c << "data: #{@value}\n\n" unless c.closed?
      end
    end

    def subscribe(out)
      @connections << out
      out << "data: #{@value}\n\n"
      @connections.reject!(&:closed?)
    end
  end

  class App < Sinatra::Base
    helpers Sinatra::Streaming

    def initialize(controller, build_interval)
      super()
      @controller = controller
      @sse_logger = SseLogger.new
      Rmk.stdout = @sse_logger.writer(:out)
      Rmk.stderr = @sse_logger.writer(:error)
      @status = Subscribable.new(:idle)
      @running = Subscribable.new(true)
      @root_build_results = RootBuildResult.new(@controller, [])
      @queue = EventMachine::Queue.new
      @build_interval = build_interval
      enqueue_build
    end

    def build(policy: nil, interval: @build_interval, jobs: nil)
      @status.value = :building
      @controller.run(policy: policy, jobs: jobs) do |result_jobs|
        @root_build_results = RootBuildResult.new(@controller, result_jobs)
        @status.value = :finished
        if interval
          EventMachine.add_timer(interval) do
            enqueue_build(policy: policy, interval: interval, jobs: jobs) if @running.value
          end
        end
        @status.value = :idle
      end
    end

    def enqueue_build(policy: nil, interval: @build_interval, jobs: nil)
      @queue.push(policy: policy, interval: interval, jobs: jobs) # rubocup:disable Style/BracesAroundHashParameters, Metrics/LineLength
      @queue.pop do |options|
        build(**options)
      end
    end

    configure do
      set :threaded, false
    end

    get '/' do
      redirect to('/build/root')
    end

    get '/build', provides: 'application/json' do
      build_result = @root_build_results.build_results['root']
      halt 404 unless build_result
      gr = Graph.new
      build_result.graph(gr)
      gr.to_json
    end

    get '/build/:id' do
      @build_result = @root_build_results.build_results[params['id']]
      @logs = @sse_logger.logs
      halt 404 unless @build_result
      @graph = Graph.new
      @build_result.graph(@graph)
      slim :build
    end

    get '/build/:id/depends' do
      @build_result = @root_build_results.build_results[params['id']]
      @logs = @sse_logger.logs
      halt 404 unless @build_result
      @build_result.depends.map { |r| { name: r.name, dir: r.dir, exception: r.exception, url: url('/build/' + r.id) } }.to_json
    end

    get '/rebuild/:id' do
      @build_result = @root_build_results.build_results[params['id']]
      halt 404 unless @build_result
      enqueue_build(policy: LocalBuildPolicy.new, jobs: @build_result.jobs, interval: nil)
      redirect to("/build/#{params['id']}")
    end

    get '/favicon.ico' do
    end

    get '/status', provides: 'text/event-stream' do
      stream(:keep_open) do |out|
        @status.subscribe(out)
      end
    end

    get '/running', provides: 'text/event-stream' do
      stream(:keep_open) do |out|
        @running.subscribe(out)
      end
    end

    post '/running/toggle' do
      enqueue_build unless @running.value
      @running.value = !@running.value
    end

    post '/cancel' do
      Tools.killall
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
