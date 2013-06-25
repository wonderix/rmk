#!/usr/bin/env ruby
require 'rubygems'
require 'digest/md5'
require 'eventmachine'
require 'fiber'
require 'optparse'
require 'em-http-request'



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


  class Material
    attr_reader :name, :plan, :depends, :block, :hidden
    attr_accessor :result
    def initialize(name,plan,depends,&block)
      @name = name
      @plan = plan
      @depends = depends
      @block = block
      @result = nil
      @hidden = []
    end
    def inspect()
      "@name=#{@name.inspect} @dir=#{@plan.dir} @depends=#{@depends.inspect}"
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
    
    def build_cache(name,depends, &block)
      return Material.new(name,self,depends,&block)
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
    def build(materials)
      result = []
      materials.each do | material |
        if material.is_a?(Material)
          result << material.result ||= material.block.call(build(material.depends).flatten,[])
        else
          result << material
        end
      end
      result
    end
  end
  
  class ModificationTimeBuildPolicy
    def initialize(readonly)
      @readonly = readonly
    end
    def build(materials)
      result = []
      materials.each do | material |
        if material.is_a?(Material)
          if material.result
            result << material.result
          else
            md5 = Digest::MD5.new
            md5.update(material.plan.md5)
            depends = build(material.depends).flatten
            depends.each { | d | md5.update(d.to_s); }
            file = File.join(material.plan.build_dir,"cache/#{md5.hexdigest}")
            begin
            	material.hidden.concat(File.open(file +".dep","rb") { | f | Marshal.load(f) })
              depends += material.hidden
            rescue Errno::ENOENT
            end
            rebuild = true
            if File.readable?(file)
              rebuild = false
              mtime = File.mtime(file)
              depends.each do | d |
                dmtime = d.respond_to?(:mtime) ? d.mtime : File.mtime(d)
                if dmtime > mtime
                  raise "Rebuilding #{Tools.relative(file)}(#{mtime}) because #{Tools.relative(d)}(#{dmtime}) is newer" if @readonly
                  rebuild = true 
                  break
                end
              end
            else
              raise "Rebuilding #{file}) because it doesn't exist" if @readonly
            end
            if rebuild
              result << Future.new(depends) do
                hidden = []
                res = material.block.call(depends,material.hidden)
                FileUtils.mkdir_p(File.dirname(file))
                File.open(file,"wb") { | f | Marshal.dump(res,f) }
                File.open(file +".dep","wb") { | f | Marshal.dump(material.hidden,f) } unless material.hidden.empty?
                material.result = res
              end
            else
              result << material.result = File.open(file,"rb") { | f | Marshal.load(f) }
            end 
          end
        else
          result << material
        end
      end
      result.map{ | r | r.is_a?(Future) ? r.value : r }
    end
  end


  class CacheBuildPolicy
  	def initialize(url)
  		@url = url
  		@policy = ModificationTimeBuildPolicy.new(false)
  	end
  	def self.md5(file)
  		Digest::MD5.hexdigest(File.open(file,'rb'){ | f | f.read()}.gsub(/\s+/,""))
  	end
  	def depends_md5(material,md5)
			material.depends.each do | d |
				if d.is_a?(Material)
					depends_md5(d,md5)
				else
					md5[d.to_s] = CacheBuildPolicy.md5(d)
				end
  		end
  	end
  	def hidden_md5(material,md5)
			material.depends.each do | d |
				if d.is_a?(Material)
					d.hidden.each do | h |
						md5[h] = CacheBuildPolicy.md5(h)
					end
					hidden_md5(d,md5)
				end
  		end
  	end
    def build(materials)
      result = []
      materials.each do | material |
        if material.is_a?(Material)
        	if material.result
          	result << material.result 
          else
          	md5 = { material.plan.to_s => CacheBuildPolicy.md5(material.plan.to_s)}
          	depends_md5(material,md5)
          	id = Digest::MD5.new
          	md5.keys.sort.each do | k |
          		id.update(k)
          		id.update(md5[k])
          	end
          	url = File.join(@url,material.name,id.hexdigest,"index")
          	f = Fiber.current
  					http = EventMachine::HttpRequest.new(url).get
						http.callback { f.resume(http) }
						http.errback  { f.resume(http) }
						http = Fiber.yield
						if http.response_header.status == 200
						else
							result = @policy.build([material])
							hmd5 = {}
							hidden_md5(material,hmd5)
          		hmd5.keys.sort.each do | k |
          			id.update(k)
          			id.update(md5[k])
          		end
          		url = File.join(@url,material.name,id.hexdigest,id.hexdigest) 
  						http = EventMachine::HttpRequest.new(url).put :body => File.open(result.first,'rb'){ | f | f.read()}
							http.callback { f.resume(http) }
							http.errback  { f.resume(http) }
							http = Fiber.yield
						end
          end
        else
          result << material
        end
      end
      result
    end
  end


end

dir = '.'
readonly = false
policy = Rmk::ModificationTimeBuildPolicy.new(readonly)
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
      materials = build_file.send(task.intern)
      # p materials
      policy.build(materials)
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
