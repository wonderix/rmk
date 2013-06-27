#!/usr/bin/env ruby
require 'rubygems'
require 'digest/md5'
require 'eventmachine'
require 'fiber'
require 'optparse'
require 'em-http-request'
require 'json'



class File
  def self.relative_path_from(src,base)
    s = src.split("/")
    b = base.split("/")
    j = 0
    return src if s[1] != b[1]
    return "./" if s == b
    for i in 0...s.length
      if s[i] != b[i]
        j = i
        break
      end
    end
    return "." if j == 0 && s.length == b.length
    (Array.new(b.length-j,"..") + s[j..-1]).join("/")
  end
end

module Rmk
  class MethodCache
    def initialize(delegate)
      @cache = Hash.new
      @delegate = delegate
    end
    def method_missing(m, *args, &block)
      key = m.to_s + args.to_s
      begin
        @cache[key] ||= @delegate.send(m,*args,&block)
      rescue Exception => exc
        #exc.backtrace.each do | c |
        #  raise "#{c} : #{exc.message} #{exc.backtrace.join("\n")}" if c =~ /build.rmk/
        #end
        raise "#{@delegate.to_s}:#{m.to_s} : #{exc.message} #{exc.backtrace.join("\n")}"
      end
    end
  end

  module PipeReader
    def initialize(fiber)
      @fiber = fiber
    end
    def receive_data(data)
      STDOUT.write(data)
    end
    def unbind
      @fiber.resume get_status.exitstatus
    end
  end

  class Future
    def initialize(name,&block)
      @name = name
      @value = nil
      current = Fiber.current
      Fiber.new do 
        begin
          @value = block.call() || true
        rescue Exception => exc
          @value = exc
        end
        EventMachine.next_tick do
          current.resume if current.alive?
        end
      end.resume
    end
    def to_s()
      "Future:#{@name}"
    end
    def value()
      while @value.nil? 
        Fiber.yield
      end
      raise @value if @value.is_a?(Exception)
      @value
    end
  end


  module Tools
    def self.relative(msg)
      msg.to_s.gsub(/(\/[^\s:]*\/)/) { File.relative_path_from($1,Dir.getwd) + "/" }
    end		
    def system(cmd)
      message = Tools.relative(cmd)
      puts(message)
      EventMachine.popen(cmd, PipeReader,Fiber.current)
      raise "Error running \"#{cmd}\"" unless Fiber.yield == 0
    end
  end


  class WorkItem
    attr_reader :name, :plan, :depends, :block, :include_depends, :file
    attr_accessor :result
    NEVER_DONE = 0
    LATELY_DONE = 1
    DONE = 2
    def initialize(name,plan,depends,include_depends,&block)
      @name = name
      @plan = plan
      @depends = depends
      @include_depends = include_depends
      @block = block
      @result = nil
      @state = NEVER_DONE
      md5 = Digest::MD5.new
      md5.update(plan.md5)
      sources.each { | s | md5.update(s); }
      @file = File.join(plan.build_dir,"cache/#{@name}/#{md5.hexdigest}")
			begin
        @result = File.open(@file,"rb") { | f | Marshal.load(f) }
        @state = LATELY_DONE
				@headers = File.open(@file +".dep","rb") { | f | Marshal.load(f) }
			rescue Errno::ENOENT
			rescue Exception
				File.delete(@file) if File.readable?(@file)
			end
    end
    
    def done?()
    	@state == DONE
    end

    def done!()
    	@state = DONE
    end
    
    def lately_done?()
    	@state >= LATELY_DONE
    end
    
    def inspect()
      "@name=#{@name.inspect} @dir=#{@plan.dir} @depends=#{@depends.inspect}"
    end
    
    def mtime()
    	File.mtime(@file)
    end
    
    def set_result(value,hdrs=nil)
    	@result = value
    	@state = DONE
    	if hdrs
    		@headers.clear
    		hdrs.each do | key ,value |
    			@headers[key] = true
    		end
			else
				headers()
			end
			FileUtils.mkdir_p(File.dirname(@file))
      File.open(@file,"wb") { | f | Marshal.dump(@result,f) }
      File.open(@file +".dep","wb") { | f | Marshal.dump(@headers,f) } unless @headers.empty?
      @result
    end
    
    def build(depends)
    	@headers ||= {}
      self.set_result(@block.call(depends,@headers),nil)
    end
    
    def sources(result = nil)
      unless @sources
        @sources  = {}
        @depends.each do | d |
          if d.is_a?(WorkItem)
            d.sources(@sources)
          else
            @sources[d.to_s] = true
          end
        end
      end
      result ? result.merge!(@sources)  : @sources.keys
    end
    
    def headers(result = nil)
      unless @headers
        @headers  = {}
        @depends.each do | d |
          d.headers(@headers) if d.is_a?(WorkItem)
        end
      end
      result ? result.merge!(@headers)  : @headers.keys
    end
  end
    
  class Plan

    BUILD_DIR = "build"
    
    attr_accessor :md5
    def initialize(build_file_cache,file,md5)
      @build_file_cache = build_file_cache
      @file = file
      @dir = File.dirname(file)
      @md5 = md5
    end
    
    def self.file=(value)
      @dir = File.dirname(value)
    end
    
    def project(file)
      @build_file_cache.load(file,@dir)
    end
    
    def self.plugin(name)
      Kernel.require File.join(File.expand_path(File.dirname(File.dirname(__FILE__))),"plugins",name + ".rb")
      include const_get(name.capitalize)
    end
    
    def work_item(name,depends, include_depends = [], &block)
      return WorkItem.new(name,self,depends,include_depends,&block)
    end
    
    def glob(pattern)
      Dir.glob(File.join(@dir,pattern))
    end
    
    def dir()
      @dir
    end
    
    def build_dir()
      File.join(@dir,BUILD_DIR)
    end
    
    def file(name)
      return File.join(@dir,name) if name.is_a?(String)
      name.to_a.map{ | x | File.join(@dir,x) }
    end
    
    def to_s()
      @file
    end
  end

  class PlanCache
    def initialize()
      @cache = Hash.new
    end
    def load(file, dir = ".")
      file = File.expand_path(File.join(dir,file))
      file = File.join(file,"build.rmk") if File.directory?(file)
      @cache[file] ||= load_inner(file)
    end
    def load_inner(file)
      build_file = Class.new(Plan)
      content = File.read(file)
      build_file.file = file
      build_file.module_eval(content,file,1)
      MethodCache.new(build_file.new(self,file,Digest::MD5.hexdigest(content)))
    end
  end
  
  class AlwaysBuildPolicy
    def build(work_items)
      result = []
      work_items.each do | work_item |
        if work_item.is_a?(WorkItem)
          result << work_item.result ||= work_item.block.call(build(work_item.depends).flatten,[])
        else
          result << work_item
        end
      end
      result
    end
  end
  
  class ModificationTimeBuildPolicy
    def initialize(readonly=false)
      @readonly = readonly
    end
    def cache(work_item,&block)
    	block.call
    end
    def build(work_items)
      result = []
      work_items.each do | work_item |
        if work_item.is_a?(WorkItem)
          if work_item.done?
            result << work_item.result
          else
            rebuild = true
            if work_item.lately_done?
              rebuild = false
              mtime = work_item.mtime
              (work_item.sources + work_item.headers).each do | d |
                dmtime = File.mtime(d)
                if dmtime > mtime
                  raise "Rebuilding #{work_item.name}(#{mtime}) because #{Tools.relative(d)}(#{dmtime}) is newer" if @readonly
                  rebuild = true 
                  break
                end
              end
            else
              raise "Rebuilding #{work_item.name}) because it doesn't exist" if @readonly
            end
            if rebuild
            	result << cache(work_item) do
              	depends = build(work_item.depends + work_item.include_depends).flatten
              	Future.new(depends) do
                	work_item.build(depends)
              	end
              end
            else
            	work_item.done!
              result << work_item.result
            end 
          end
        else
          result << work_item
        end
      end
      result.map{ | r | r.is_a?(Future) ? r.value : r }
    end
  end

  class CacheBuildPolicy < ModificationTimeBuildPolicy
  	def initialize(url)
  		@url = url
  		@md5_cache = {}
  	end
  	def md5(file)
  		@md5_cache[file] ||= begin
  		  Digest::MD5.hexdigest(File.open(file,'rb'){ | f | f.read()}.gsub(/\s+/,""))
  		rescue Errno::ENOENT
  			"0000"
  		end
  	end
  	def put(path,body)
			f = Fiber.current
			http = EventMachine::HttpRequest.new(File.join(@url,path)).put :body => body
			http.callback { f.resume(http) }
			http.errback  { f.resume(http) }
			http = Fiber.yield
  	end
  	def get(path)
      f = Fiber.current
			http = EventMachine::HttpRequest.new(File.join(@url,path)).get
			http.callback { f.resume(http) }
			http.errback  { f.resume(http) }
			http = Fiber.yield
			code = http.response_header.status
			raise Errno::ENOENT.new("File '#{path}' not found: #{code}") unless code == 200
			http.response
  	end
    def cache(work_item,&block)
			sources = work_item.sources
			sources << work_item.plan.to_s
			
			id = Digest::MD5.new
			sources.sort.each do | k |
				id.update(k)
				id.update(md5(k))
			end
			id = id.hexdigest
			result = nil
			begin
				JSON.parse(get(File.join(work_item.name,id,"index"))).each do | entries |
					entries.each do | hid , headers |
						found = true
						headers.each do | file , x |
							found &&= ( md5(file) == x )
						end
						if found
							result = JSON.parse(get(File.join(work_item.name,id,hid+".json")))['result']
							FileUtils.mkdir_p(File.dirname(result))
							File.open(result,'wb') { | f | f.write(get(File.join(work_item.name,id,hid+".bin"))) }
							puts("GET #{result}")
							work_item.set_result(result,headers)
							break
						end
					end
				end
      rescue Errno::ENOENT
			rescue Exception => exc
        STDERR.puts exc.message
        STDERR.puts exc.backtrace.join("\n")
			end
			unless result
				result = block.call()
				result = result.value if result.is_a?(Future)
				headers = {}
				hid = Digest::MD5.new
				work_item.headers.sort.each do | k |
					hid.update(k)
					x = md5(k)
					headers[k] = x
					hid.update(x)
				end
				hid = hid.hexdigest
				if result.is_a?(String)
					put(File.join(work_item.name,id,hid+".json"),{ 'result' => result}.to_json)
					put(File.join(work_item.name,id,hid+".bin"),File.open(result,'rb'){ | f | f.read()})
					put(File.join(work_item.name,id,hid+".dep"),{ hid => headers}.to_json)
				end
			end
			result 
    end
  end


end

dir = '.'
policy = Rmk::ModificationTimeBuildPolicy.new()
OptionParser.new do |opts|
  opts.banner = "Usage: rmk.rb [options] [target]"

  opts.on("-C", "--directory [directory]", "Change to directory ") do |v|
    dir = v
  end
  opts.on("-r", "--readonly", "Raise exception when files are rebuild") do |v|
    policy = Rmk::ModificationTimeBuildPolicy.new(true)
  end
  opts.on("-a", "--always", "build files unconditionally") do |v|
    policy = Rmk::AlwaysBuildPolicy.new()
  end
  opts.on("-c", "--cache [url]", "use build cache ") do |v|
    policy = Rmk::CacheBuildPolicy.new(v)
  end
end.parse!

result = 0
build_file_cache = Rmk::PlanCache.new()
build_file = build_file_cache.load("build.rmk",dir)
task = ARGV[0] || "all"
EventMachine.run do
  Fiber.new do 
    begin
      work_items = build_file.send(task.intern)
      # p work_items
      policy.build(work_items)
      puts "Build OK"
    rescue Exception => exc
      STDERR.puts exc.message
      STDERR.puts exc.backtrace.join("\n")
      puts "Build Failed"
      result = 1
    end
    EventMachine.stop
  end.resume
end
exit(result)
