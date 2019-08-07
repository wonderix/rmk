# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/streaming'
require 'thin'
require 'slim'
require 'json'
require 'ostruct'

# rubocop:disable Documentation

module Rmk
  class BuildGraph
    def self.scan(job, graph)
      return unless job.is_a?(Rmk::Job)
      return graph if graph[job.id]

      graph[job.id] = { name: job.name, dir: job.plan.dir, exception: job.exception, depends: job.depends.select { |j| j.is_a?(Rmk::Job) }.map(&:id) }
      job.depends.each { |d| BuildGraph.scan(d, graph) }
    end

    def self.scan_root(controller, jobs)
      jobs_with_exception = jobs.reject { |i| i.exception.nil? }
      exception = jobs_with_exception.empty? ? nil : jobs_with_exception.first.exception
      graph = {}
      graph['root'] = { name: controller.task, dir: controller.dir, exception: exception, depends: jobs.map(&:id) }
      jobs.each { |j| BuildGraph.scan(j, graph) }
      graph
    end
  end

  class SseLogger
    class Writer
      def initialize(channel, build_history)
        @channel = channel
        @build_history = build_history
      end

      def write(data)
        # $stdout.write(data)
        data.split("\n").each do |message|
          next if message.empty?

          log = { channel: @channel, message: message,
                  time: Time.now.strftime('%H:%M:%S') }
          @build_history.current.log(log)
        end
      end
    end

    def writer(channel, build_history)
      Writer.new(channel, build_history)
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

  class BuildHistoryEntry
    attr_accessor :succeeded
    def initialize(dir)
      @dir = dir
      @connections = []
      @succeeded = true
      FileUtils.mkdir_p(@dir)
    end

    def start
      @logs&.close
      @connections.each do |c|
        c << "data: null\n\n" unless c.closed?
      end
      @logs = File.open(File.join(@dir, 'logs.json'), 'w')
      @started_at = Time.now
    end

    def id
      File.basename(@dir)
    end

    def graph=(graph)
      @graph = graph
      @succeeded = graph['root'][:exception].nil?
    end

    def graph
      @graph || JSON.parse(File.read(File.join(@dir, 'graph.json')))
    rescue Errno::ENOENT
      { 'root' => { 'name' => '???', 'depends' => [] } }
    end

    def logs
      File.readlines(File.join(@dir, 'logs.json')).map { |line| JSON.parse(line) }
    rescue Errno::ENOENT
      []
    end

    def info
      result = begin
        JSON.parse(File.read(File.join(@dir, 'info.json')))
               rescue Errno::ENOENT
                 { 'started_at' => @started_at, 'succeeded' => @succeeded }
      end
      result['id'] = id
      result
    end

    def log(log)
      @logs ||= File.open(File.join(@dir, 'logs.json'), 'a')
      @connections.each do |c|
        c << "data: #{log.to_json}\n\n" unless c.closed?
      end
      @logs.puts(log.to_json)
      @logs.flush
    end

    def commit(target)
      @logs.close
      @logs = nil
      g = graph
      File.write(File.join(@dir, 'graph.json'), g.to_json)
      File.write(File.join(@dir, 'info.json'), { started_at: @started_at, finished_at: Time.now, succeeded: @succeeded }.to_json)
      FileUtils.mv(@dir, target, verbose: false, force: true)
      FileUtils.mkdir_p(@dir)
      graph = g
    end

    def subscribe(out)
      @connections << out
      logs.each do |log|
        out << "data: #{log.to_json}\n\n"
      end
      @connections.reject!(&:closed?)
    end
  end

  class BuildHistory
    def initialize(dir)
      @dir = dir
      @builds = Dir.glob(File.join(dir, '*')).map { |f| File.basename(f) }.select { |d| d =~ /^\d+$/ }.map(&:to_i).sort { |x, y| y <=> x }
      @counter = @builds.first.to_i
      @current = BuildHistoryEntry.new(File.join(@dir, 'current'))
    end

    attr_reader :current

    def list
      [@current] + @builds.map { |b| BuildHistoryEntry.new(File.join(@dir, b.to_s)) }
    end

    def get(id)
      return @current if id == 'current'

      dir = File.join(@dir, id)
      File.directory?(dir) ? BuildHistoryEntry.new(File.join(@dir, id)) : nil
    end

    def commit
      @counter += 1
      @builds.unshift @counter
      @current&.commit(File.join(@dir, @counter.to_s))
    end
  end

  class App < Sinatra::Base
    helpers Sinatra::Streaming

    def initialize(controller, build_interval)
      super()
      @build_history = BuildHistory.new(File.join(controller.dir, '.rmk/history'))
      @controller = controller
      @sse_logger = SseLogger.new
      Rmk.stdout = @sse_logger.writer(:out, @build_history)
      Rmk.stderr = @sse_logger.writer(:error, @build_history)
      @status = Subscribable.new(:idle)
      @running = Subscribable.new(true)
      @queue = EventMachine::Queue.new
      @build_interval = build_interval
      enqueue_build
    end

    def build(policy: nil, interval: @build_interval, jobs: nil)
      @status.value = :building
      @build_history.current.start
      @build_history.current.graph = BuildGraph.scan_root(@controller,@controller.load_jobs)
      @controller.run(policy: policy, jobs: jobs) do |result_jobs|
        graph = BuildGraph.scan_root(@controller, result_jobs)
        @build_history.current.graph = graph
        if result_jobs.reduce(false) { |acc, j| acc ||= j.modified? }
          @build_history.commit
        end
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
      redirect to('/build/current')
    end

    get '/build/:id', provides: 'text/html' do
      @build = @build_history.get(params['id'])
      halt 404 unless @build
      slim :build
    end

    get '/history', provides: 'application/json' do
      @build_history.list.map(&:info).to_json
    end

    get '/build/:id', provides: 'application/json' do
      build = @build_history.get(params['id'])
      halt 404 unless build
      build.graph.to_json
    end

    get '/rebuild/:id' do
      halt 404 unless @build_history.get(params['id'])
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

    get '/build/:id/log/stream', provides: 'text/event-stream' do
      build = @build_history.get(params['id'])
      halt 404 unless build
      stream(:keep_open) do |out|
        build.subscribe(out)
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
