# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/streaming'
require 'thin'
require 'slim'

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

  class App < Sinatra::Base
    helpers Sinatra::Streaming

    def initialize(controller, build_interval)
      super()
      @controller = controller
      @build_interval = build_interval
      @connections = []
      @root_build_results = RootBuildResult.new(@controller, [])
      build
    end

    def build
      @connections.each { |c| c << "data: true\n\n" }
      @controller.run do |jobs|
        @root_build_results = RootBuildResult.new(@controller, jobs)
        @connections.each { |c| c << "data: false\n\n" }
        EventMachine.add_timer(@build_interval) do
          build
        end
      end
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
        @connections << out

        # purge dead connections
        @connections.reject!(&:closed?)
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

        Rack::Server.start(
          app: dispatch,
          server: 'thin',
          Host: '0.0.0.0',
          Port: '8181',
          signals: false
        )
      end
    end
  end
end
