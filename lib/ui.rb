require 'sinatra/base'
require 'thin'
require "slim"


module Rmk
  class BuildResult
    attr_accessor :depends

    def initialize(item)
      @item = item
      @depends = []
    end

    def name()
      @item.name
    end

    def dir()
      @item.plan.dir
    end

    def id()
      @item.id()
    end

    def exception()
      @item.exception
    end

  end

  class RootBuildResult
    attr_accessor :depends
    attr_reader :build_results

    def initialize(controller,jobs)
      @controller = controller
      @build_results = {}
      @build_results['root'] = self
      @depends = scan(jobs)
    end

    def name()
      @controller.task
    end

    def dir()
      @controller.dir
    end

    def id()
      'root'
    end

    def exception()
      list = @depends.select { |i| i.exception != nil}
      list.empty? ? nil : list.first.exception
    end

    def scan(jobs)
      result = []
      jobs.each do | item |
        if item.is_a?(Rmk::Job)
          build_result = @build_results[item.id] ||= BuildResult.new(item)
          build_result.depends = scan(item.depends)
          result << build_result
        end
      end
      result
    end
  end


  class ResultScanner
    def initialize(controller)
    end


  end

  class App < Sinatra::Base

    def initialize(controller)
      super()
      @controller = controller
      build()
      EventMachine.add_periodic_timer(5) do
        build()
      end
    end

    def build()
      @controller.run do | jobs |
        @root_build_results = RootBuildResult.new(@controller,jobs)
      end
    end

    configure do
      set :threaded, false
    end

    get "/" do
      redirect "/build/root"
    end


    get "/build/:id" do
      @build_result = @root_build_results.build_results[params['id']]
      halt 404 unless @build_result
      slim :build
    end

    get "/favicon.ico" do
    end

    def self.run(controller)

      EventMachine.run do

        web_app = App.new(controller)

        dispatch = Rack::Builder.app do
          map '/' do
            run web_app
          end
        end

        Rack::Server.start({
          app:    dispatch,
          server: 'thin',
          Host:   '0.0.0.0',
          Port:   '8181',
          signals: false,
        })
      end
    end

  end
end