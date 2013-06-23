#!/usr/bin/env ruby
require 'rubygems'
require 'digest/md5'
require 'eventmachine'
require 'fiber'
require 'optparse'

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

class String
  def value()
    self
  end
end

class Array
	def value()
		self
	end
end

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

class BuildFuture
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
  	"BuildFuture:#{@name}"
  end
  def value()
		while @value.nil? 
			Fiber.yield
		end
		raise @value if @value.is_a?(Exception)
		@value
  end
end


module BuildTools
	def self.relative(msg)
    msg.to_s.gsub(/(\/[^\s:]*\/)/) { File.relative_path_from($1,Dir.getwd) + "/" }
	end		
  def system(cmd)
    message = BuildTools.relative(cmd)
    puts(message)
    EventMachine.popen(cmd, PipeReader,Fiber.current)
    raise "Error running xxx" unless Fiber.yield == 0
  end
end

class BuildFile

  BUILD_DIR = "build"
  
  attr_accessor :md5
  def initialize(build_file_cache,file,opts,md5)
    @build_file_cache = build_file_cache
    @file = file
    @dir = File.dirname(file)
    @opts = opts
    @md5 = md5
  end
  
  def self.file=(value)
    @dir = File.dirname(value)
  end
  
  def project(file)
    @build_file_cache.load(file,@dir,@opts)
  end
  
  def self.plugin(name)
    Kernel.require File.join(File.expand_path(File.dirname(File.dirname(__FILE__))),"plugins",name + ".rb")
    include const_get(name.capitalize)
  end
  
  def build_cache(depends,&block)
    md5 = Digest::MD5.new
    c = caller
    md5.update(@md5)
    depends.each { | d | md5.update(d.to_s); }
    file = File.join(@dir,BUILD_DIR,"cache/#{md5.hexdigest}")
    begin
      depends += File.open(file +".dep","rb") { | f | Marshal.load(f) } 
    rescue Errno::ENOENT
    end
    rebuild = true
    if File.readable?(file)
      rebuild = false
      mtime = File.mtime(file)
      depends.each do | d |
        dmtime = d.respond_to?(:mtime) ? d.mtime : File.mtime(d)
        if dmtime > mtime
        	raise "Rebuilding #{BuildTools.relative(file)}(#{mtime}) because #{BuildTools.relative(d)}(#{dmtime}) is newer" if @opts[:why]
          rebuild = true 
          break
        end
      end
    else
    	raise "Rebuilding #{file}) because it doesn't exist" if @opts[:why]
    end
    if rebuild
    	result = BuildFuture.new(depends) do
      	hidden = []
      	res = block.call(hidden) 
      	FileUtils.mkdir_p(File.dirname(file))
      	File.open(file,"wb") { | f | Marshal.dump(res,f) }
      	File.open(file +".dep","wb") { | f | Marshal.dump(hidden,f) } unless hidden.empty?
      	res
      end
    else
      result = File.open(file,"rb") { | f | Marshal.load(f) }
    end 
    result
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

class BuildFileCache
  def initialize()
    @cache = Hash.new
  end
  def load(file, dir = ".", opts = {})
    file = File.expand_path(File.join(dir,file))
    file = File.join(file,"build.rmk") if File.directory?(file)
    @cache[file] ||= load_inner(file,opts)
  end
  def load_inner(file,opts)
    build_file = Class.new(BuildFile)
    content = File.read(file)
    build_file.file = file
    build_file.module_eval(content,file,1)
    MethodCache.new(build_file.new(self,file,opts,Digest::MD5.hexdigest(content)))
  end
end

options = {:dir => '.'}
OptionParser.new do |opts|
  opts.banner = "Usage: rmk.rb [options] [target]"

  opts.on("-w", "--why", "Show why rebuilding a target") do |v|
    options[:why] = v
  end
  opts.on("-C", "--directory", "change to directory") do |v|
    options[:dir] = v
  end
end.parse!

result = 0
EventMachine.run do
  Fiber.new do 
    build_file_cache = BuildFileCache.new()
    build_file = build_file_cache.load("build.rmk",options[:dir],options)
    task = ARGV[0] || "all"
    begin
      build_file.send(task.intern)
      puts "Build OK"
    rescue Exception => exc
      STDERR.puts exc.message
      puts "Build Failed"
      result = 1
    end
    EventMachine.stop
  end.resume
end
exit(result)
