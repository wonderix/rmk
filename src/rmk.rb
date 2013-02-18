#!/usr/bin/env ruby
require 'rubygems'
require 'digest/md5'

class MethodCache
  def initialize(delegate)
    @cache = Hash.new
    @delegate = delegate
  end
  def method_missing(m, *args, &block)
    key = args.to_s
    begin
      @cache[key] ||= @delegate.send(m,*args,&block)
    rescue Exception => exc
      exc.backtrace.each do | c |
        raise "#{c} : #{exc.message}" if c =~ /build.rmk/
      end
      raise "#{@delegate.to_s}:#{m.to_s} : #{exc.message}"
    end
  end
end


class File
  def self.relative_path_from(src,base)
    s = src.split("/")
    b = base.split("/")
    j = 0
    for i in 0...s.length
      if s[i] != b[i]
        j = i
        break
      end
    end
    (Array.new(b.length-j,"..") + s[j..-1]).join("/")
  end
end

class BuildFile

  BUILD_DIR = "build"
  
  def initialize(build_file_cache,file)
    @build_file_cache = build_file_cache
    @file = file
    @dir = File.dirname(file)
  end
  
  def dependency(file)
    @build_file_cache.load(file,@dir)
  end
  
  def self.plugin(name)
    require File.join(File.expand_path(File.dirname(File.dirname(__FILE__))),"plugins",name + ".rb")
    include const_get(name.capitalize)
  end
  
  def system(cmd)
    puts(cmd)
    Kernel.system(cmd)
    raise "Error running #{cmd}" unless $? == 0
  end
  
  def build_cache(depends,&block)
    md5 = Digest::MD5.new
    c = caller
    md5.update(c[0])
    md5.update(c[1])
    depends.each { | d | md5.update(d) }
    file = File.join(@dir,BUILD_DIR,"cache/#{md5.hexdigest}")
    rebuild = true
    if File.readable?(file)
      rebuild = false
      depends.each do | d |
        if File.mtime(d) > File.mtime(file)
          rebuild = true 
          break
        end
      end
    end
    if rebuild
      result = block.call() 
      FileUtils.mkdir_p(File.dirname(file))
      File.open(file,"wb") { | f | Marshal.dump(result,f) }
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
    File.join(@dir,name)
  end
  def to_s()
    @file
  end
end

class BuildFileCache
  def initialize()
    @cache = Hash.new
  end
  def load(file,dir = ".")
    file = File.expand_path(File.join(dir,file))
    file = File.join(file,"build.rmk") if File.directory?(file)
    @cache[file] ||= load_inner(file)
  end
  def load_inner(file)
    build_file = Class.new(BuildFile)
    content = File.read(file)
    build_file.module_eval(content,file,1)
    MethodCache.new(build_file.new(self,file))
  end
end


    
build_file_cache = BuildFileCache.new()
build_file = build_file_cache.load("build.rmk")
task = ARGV[0] || "all"
begin
  p build_file.send(task.intern)
rescue Exception => exc
  STDERR.puts exc.message
  exit(1)
end
