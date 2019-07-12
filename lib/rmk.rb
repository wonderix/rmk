#!/usr/bin/env ruby
require 'rubygems'
require 'digest/md5'
require 'eventmachine'
require 'fiber'
require 'optparse'
require 'em-http-request'
require 'json'
require 'stringio'
require 'tee'
require 'uri'



class File
  def self.relative_path_from(src,base)
    s = src.split("/")
    b = base.split("/")
    j = s.length
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

class String
  def result()
    self
  end
end

class Array
  def result()
    self
  end
end

module Rmk

  def self.verbose()
    @verbose.to_i
  end

  def self.verbose=(level)
    @verbose = level
  end

  RMK_DIR = File.expand_path('~/.rmk')

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
    def initialize(fiber,out)
      @fiber = fiber
      @out = out
    end
    def receive_data(data)
      @out.write(data)
    end
    def unbind
      @out.close if @out != STDOUT
      @fiber.resume get_status.exitstatus
    end
  end

  class Future
    def initialize(name,&block)
      @name = name
      @result = nil
      current = Fiber.current
      Fiber.new do
        begin
          @result = block.call() || true
        rescue Exception => exc
          @result = exc
        end
        EventMachine.next_tick do
          current.resume if current.alive?
        end
      end.resume
    end
    def to_s()
      "Future:#{@name}"
    end
    def result()
      while @result.nil?
        Fiber.yield
      end
      raise @result if @result.is_a?(Exception)
      @result
    end
  end


  module Tools

    def self.relative(msg)
      msg.to_s.gsub(/(\/[^\s:]*\/)/) { File.relative_path_from($1,Dir.getwd) + "/" }
    end

    def system(cmd)
      message = Rmk.verbose > 0 ? cmd : Tools.relative(cmd)
      stringio = StringIO.new()
      puts(message)
      out = Tee.open(stringio)
      if cmd =~ /(.*)\s*>\s*(\S*)$/
        out = File.open($2,'wb')
        cmd = $1
      end
      EventMachine.popen("sh -c '#{cmd} 2>&1'", PipeReader,Fiber.current,out)
      raise "#{cmd}\n#{stringio.string}" unless Fiber.yield == 0
      stringio.string
    end
  end


  class Job

    def self.threads=(value)
      @threads = value
    end

    def self.threads()
      @threads || 100
    end

    attr_reader :name, :plan, :depends, :block, :include_depends, :file
    attr_accessor :exception
    def initialize(name,plan,depends,include_depends,&block)
      depends = [depends] unless depends.is_a?(Array)
      @name = name
      @plan = plan
      @depends = depends
      @include_depends = include_depends
      @block = block
      @result = nil
      @exception = nil
      md5 = Digest::MD5.new
      md5.update(plan.md5)
      sources.each { | s | md5.update(s.to_s); }
      @file = File.join(plan.build_dir,"cache/#{@name}/#{md5.hexdigest}")
    end

    def id()
      md5 = Digest::MD5.new
      md5.update(@plan.md5)
      md5.update(@plan.dir)
      md5.update(@name)
      md5.hexdigest
    end

    def last_result()
      unless @last_result
        begin
          @last_result = File.open(@file,"rb") { | f | Marshal.load(f) }
        rescue Errno::ENOENT
        rescue Exception
          puts "Removing #{@file}"
          File.delete(@file) if File.readable?(@file)
        end
        begin
          @headers = File.open(@file +".dep","rb") { | f | Marshal.load(f) }
        rescue Errno::ENOENT
          @headers = nil
        rescue Exception
          puts "Removing #{@file+".dep"}"
          File.delete(@file+".dep") if File.readable?(@file+".dep")
        end
      end
      @last_result
    end

    def use_last_result()
      @result = @last_result
    end

    def inspect()
      "<Job @name=#{@name.inspect} @dir=#{@plan.dir} @depends=#{@depends.inspect} @result=#{@result.inspect}>"
    end

    def mtime()
      File.mtime(@file)
    end

    def import(result,headers)
      @result = result
      @headers = {}
      headers.each do | key ,value |
        @headers[key] = true
      end
      save(@result)
    end

    def save(result)
      FileUtils.mkdir_p(File.dirname(@file))
      File.open(@file,"wb") { | f | Marshal.dump(result,f) }
      File.open(@file +".dep","wb") { | f | Marshal.dump(@headers,f) } if @headers && !@headers.empty?
      result
    end

    def result()
      if @result.is_a?(Future)
        begin
          @result = @result.result
          @exception = nil
        rescue Exception => exc
          @exception = exc
          raise exc
        end
      end
      @result
    end

    def build(policy)
      begin
        policy.build(self.depends + self.include_depends)
      rescue Exception => exc
        @exception = exc
        raise exc
      end
      @result = Future.new(@name) do
        headers()
        self.depends.map{|x| x.result()}
        result = @block.call(@headers)
        save(result)
      end
      return result() if Job.threads == 1
      @result
    end

    def sources(result = nil)
      unless @sources
        @sources  = {}
        @depends.each do | d |
          if d.is_a?(Job)
            d.sources(@sources)
          else
            @sources[d.to_s] = d
          end
        end
      end
      result ? result.merge!(@sources)  : @sources.values
    end

    def headers(result = nil)
      unless @headers
        @headers  = {}
        @depends.each do | d |
          d.headers(@headers) if d.is_a?(Job)
        end
      end
      result ? result.merge!(@headers)  : @headers.keys
    end
    def to_s()
      @name
    end
    def to_a()
      [ self ]
    end
  end

  class Plan

    BUILD_DIR = '.rmk'

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

    def job(name,depends, include_depends = [], &block)
      return Job.new(name,self,depends,include_depends,&block)
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
    include Tools
    def initialize()
      @cache = Hash.new
    end

    def load(file, dir = ".")
      case dir
      when /git@([^:]*):(.*)\/(.*)/
        dir = git_pull(dir,File.join(RMK_DIR,$3.sub(/\.git$/,"")))
      when /https{0,1}:\/\//
        uri = URI.parse(dir)
        dir = git_pull(dir,File.join(RMK_DIR,File.basename(uri.path).sub(/\.git$/,"")))
      end
      file = File.expand_path(File.join(dir,file))
      file = File.join(file,"build.rmk") if File.directory?(file)
      @cache[file] ||= load_inner(file)
    end

    def git_pull(remote,local)
      if File.directory?(local)
        system("git  -C #{local} pull")
      else
        FileUtils.mkdir_p(File.dirname(local))
        system("git clone --single-branch --branch master #{remote} #{local}")
      end
      return local
    end

    def load_inner(file)
      plan_class = Class.new(Plan)
      content = File.read(file)
      plan_class.file = file
      plan_class.module_eval(content,file,1)
      MethodCache.new(plan_class.new(self,file,Digest::MD5.hexdigest(content)))
    end

  end

  class AlwaysBuildPolicy
    def build(jobs)
      jobs.each do | job |
        if job.is_a?(Job)
          unless job.result
            job.build(self)
          end
        end
      end
      jobs.map { | x |  x.result }
    end
  end

  class ModificationTimeBuildPolicy
    def initialize(readonly=false)
      @readonly = readonly
    end
    def cache(job,&block)
      block.call
    end
    def build(jobs)
      jobs.each do | job |
        if job.is_a?(Job)
          unless job.result
            rebuild = true
            if job.last_result
              rebuild = false
              mtime = job.mtime
              (job.sources + job.headers).each do | d |
                dmtime = d.respond_to?(:mtime) ? d.mtime : File.mtime(d)
                if dmtime > mtime
                  raise "Rebuilding #{job.name}(#{mtime}) because #{Tools.relative(d)}(#{dmtime}) is newer" if @readonly
                  rebuild = true
                  break
                end
              end
            else
              raise "Rebuilding #{job.name} because it doesn't exist" if @readonly
            end
            if rebuild
              cache(job) do
                job.build(self)
              end
            else
              job.use_last_result
            end
          end
        end
      end
      jobs.map { | x |  x.result }
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
    def cache(job,&block)
      sources = job.sources
      sources << job.plan.to_s

      id = Digest::MD5.new
      sources.sort.each do | k |
        id.update(k)
        id.update(md5(k))
      end
      id = id.hexdigest
      result = nil
      begin
        JSON.parse(get(File.join(job.name,id,"index"))).each do | entries |
          entries.each do | hid , headers |
            found = true
            headers.each do | file , x |
              found &&= ( md5(file) == x )
            end
            if found
              result = JSON.parse(get(File.join(job.name,id,hid+".json")))['result']
              FileUtils.mkdir_p(File.dirname(result))
              File.open(result,'wb') { | f | f.write(get(File.join(job.name,id,hid+".bin"))) }
              puts("GET #{result}")
              job.import(result,headers)
              break
            end
          end
        end
      rescue Errno::ENOENT
      rescue Exception => exc
        STDERR.puts exc.message
        STDERR.puts exc.backtrace.join("\n")
      end
      unless job.result
        block.call()
        headers = {}
        hid = Digest::MD5.new
        job.headers.sort.each do | k |
          hid.update(k)
          x = md5(k)
          headers[k] = x
          hid.update(x)
        end
        hid = hid.hexdigest
        if job.result.is_a?(String)
          put(File.join(job.name,id,hid+".json"),{ 'result' => job.result}.to_json)
          put(File.join(job.name,id,hid+".bin"),File.open(job.result,'rb'){ | f | f.read()})
          put(File.join(job.name,id,hid+".dep"),{ hid => headers}.to_json)
        end
      end
    end
  end


  class Controller
    attr_accessor :dir, :policy, :task

    def initialize()
      @dir = Dir.getwd()
      @policy = ModificationTimeBuildPolicy.new()
      @task = "all"
    end

    def run()
      result = 0
      EventMachine.run do
        Fiber.new do
          build_file_cache = PlanCache.new()
          build_file = build_file_cache.load("build.rmk",@dir)
          jobs = nil
          begin
            jobs = build_file.send(@task.intern)
            item = @policy.build(jobs)
            p item.result if Rmk.verbose > 0
            puts "Build OK"
          rescue Exception => exc
            STDERR.puts exc.message
            STDERR.puts exc.backtrace.join("\n")  if Rmk.verbose > 0
            puts "Build Failed"
            result = 1
          end
          yield jobs if block_given?
        end.resume
      end
      return result
    end

  end

end

