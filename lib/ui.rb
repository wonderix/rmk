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
    def self.scan(job,graph)
      return unless job.is_a?(Rmk::Job)
      return graph if graph[job.id]
      graph[job.id] = { name: job.name, dir: job.plan.dir, exception: job.exception, depends: job.depends.select{|j| j.is_a?(Rmk::Job)}.map(&:id) }
      job.depends.each { |d| BuildGraph.scan(d,graph) }
    end

    def self.scan_root(controller, jobs)
      list = jobs.reject { |i| i.exception.nil? }
      graph = {}
      graph['root'] = { name: controller.task, dir: controller.dir, exception: list.empty? ? nil : list.first.exception, depends: jobs.map(&:id) }
      jobs.each { |j| BuildGraph.scan(j,graph) }
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

    def writer(channel,build_history)
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

    def initialize(dir)
      @dir = dir
      @connections = []
      FileUtils.mkdir_p(@dir)
    end

    def id
      File.basename(@dir)
    end

    def graph=(graph)
      File.write(File.join(@dir,"graph.json"),graph.to_json)
    end

    def graph
      JSON.parse(File.read(File.join(@dir,"graph.json")))
    rescue Errno::ENOENT
      {}
    end

    def logs
      File.readlines(File.join(@dir,"logs.json")).map{ |line| JSON.parse(line)}
    rescue Errno::ENOENT
      []
    end

    def log(log)
      @logs = File.open(File.join(@dir,"logs.json"),"a") unless @logs
      @connections.each do |c|
        c << "data: #{log.to_json}\n\n" unless c.closed?
      end
      @logs.puts(log.to_json)
    end

    def commit(target)
      @logs.close
      @logs = nil
      FileUtils.mv(@dir, target, :verbose => false, :force => true)
      FileUtils.mkdir_p(@dir)
    end

    def subscribe(out)
      @connections << out
      @connections.reject!(&:closed?)
    end
  end


  class BuildHistory
    def initialize(dir)
      @dir = dir
      @builds = Dir.glob(File.join(dir,"*")).select { |d| d =~ /^\d=$/}.map(&:to_i).sort {|x,y| y <=> x}
      @counter = @builds.first.to_i
      @current = BuildHistoryEntry.new(File.join(@dir,'current'))
    end

    def current
      @current
    end

    def list
      @builds
    end

    def get(id)
      return @current if id == 'current'
      dir = File.join(@dir,id)
      File.directory?(dir) ? BuildHistoryEntry.new(File.join(@dir,id)) : nil
    end

    def commit
      @counter += 1
      @builds << @counter
      @current.commit(File.join(@dir,@counter.to_s)) if @current
    end
  end

  class App < Sinatra::Base
    helpers Sinatra::Streaming

    def initialize(controller, build_interval)
      super()
      @build_history = BuildHistory.new(File.join(controller.dir,".rmk/history")) 
      @controller = controller
      @sse_logger = SseLogger.new
      Rmk.stdout = @sse_logger.writer(:out,@build_history)
      Rmk.stderr = @sse_logger.writer(:error,@build_history)
      @status = Subscribable.new(:idle)
      @running = Subscribable.new(true)
      @queue = EventMachine::Queue.new
      @build_interval = build_interval
      enqueue_build
    end

    def build(policy: nil, interval: @build_interval, jobs: nil)
      @status.value = :building
      @controller.run(policy: policy, jobs: jobs) do |result_jobs|
        graph = BuildGraph.scan_root(@controller, result_jobs)
        @build_history.current.graph = graph
        if result_jobs.reduce(false) { |acc ,j| acc ||= j.modified || j.exception }
          @build_history.commit
          @build_history.current.graph = graph
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

    get '/build/:id' do
      @build = @build_history.get(params['id'])
      halt 404 unless @build
      slim :build
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
