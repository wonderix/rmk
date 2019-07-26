#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'digest/md5'
require 'eventmachine'
require 'fiber'
require 'optparse'
require 'em-http-request'
require 'json'
require 'stringio'
require 'uri'
require 'open3'
require 'yaml'

# rubocop:disable Documentation

class File
  def self.relative_path_from(src, base)
    s = src.split('/')
    b = base.split('/')
    j = s.length
    return src if s[1] != b[1]
    return './' if s == b

    (0...s.length).each do |i|
      if s[i] != b[i]
        j = i
        break
      end
    end
    return '.' if j.zero? && s.length == b.length

    (Array.new(b.length - j, '..') + s[j..-1]).join('/')
  end
end

class String
  def result
    self
  end
end

class Array
  def result
    self
  end
end

module Rmk
  class << self
    attr_accessor :stderr, :stdout, :verbose
  end

  Rmk.stdout = $stdout
  Rmk.stderr = $stderr
  Rmk.verbose = 0

  RMK_DIR = File.expand_path('~/.rmk')

  class MethodCache
    def initialize(delegate)
      @cache = {}
      @delegate = delegate
    end

    def method_missing(m, *args, &block) # rubocop:disable MethodMissingSuper, MissingRespondToMissing, LineLength
      key = m.to_s + args.to_s
      begin
        @cache[key] ||= @delegate.send(m, *args, &block)
      rescue StandardError => e
        raise "#{@delegate}:#{m} : #{e.message} #{e.backtrace.join("\n")}"
      end
    end
  end

  class Future
    def initialize(name, &block)
      @name = name
      @result = nil
      current = Fiber.current
      Fiber.new do
        begin
          @result = block.call || true
        rescue Exception => e # rubocop:disable RescueException
          @result = e
        end
        EventMachine.next_tick do
          current.resume if current.alive?
        end
      end.resume
    end

    def to_s
      "Future:#{@name}"
    end

    def result
      Fiber.yield while @result.nil?
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  module Popen3Reader
    def initialize(out,fiber)
      @out = out
      @fiber = fiber
      @closed = false
    end

    def notify_readable
      @out.write(@io.readpartial(1024))
    rescue EOFError
      @closed = true
      @fiber.resume
    end

    def closed?
      @closed
    end
  end

  class Tee
    def initialize(*out)
      @out = out
    end

    def write(data)
      @out.each { |o| o.write(data) }
    end
  end

  class BuildError < StandardError
    attr_reader :dir
    def initialize(msg,dir)
      super(msg)
      @dir = dir
    end
  end

  module Tools
    class << self
      attr_accessor :pids, :trace
      def relative(msg)
        msg.to_s.gsub(%r{(/[^\s:]*/)}) do
          File.relative_path_from(Regexp.last_match(1), Dir.getwd) + '/'
        end
      end

      def killall
        pids.each do |pid, command|
          begin
            Process.kill('TERM', pid)
          rescue Errno::ESRCH # rubocop:disable Lint/HandleExceptions
          end
        end
        pids.clear
      end
    end

    Tools.pids = {}
    Tools.trace = true

    def system(cmd, chdir: nil)
      out = StringIO.new
      popen3(cmd, out: Tee.new(out, Rmk.stdout), chdir: chdir)
      out.string
    end

    def capture2(cmd, chdir: nil, trace: false)
      out = StringIO.new
      popen3(cmd, out: out, chdir: chdir, trace: trace)
      out.string
    end

    def popen3(cmd, out: Rmk.stdout, err: Rmk.stderr, chdir: nil, stdin_data: nil, trace: Tools.trace)
      cmd_string = cmd.is_a?(Array) ? cmd.join(' ') : cmd
      message = Rmk.verbose.positive? ? cmd_string : Tools.relative(cmd_string)
      out.write(message + "\n") if trace
      exception_buffer = StringIO.new
      opts = {}
      opts[:chdir] = chdir || dir
      popen3_inner(cmd, **opts) do |stdin, stdout, stderr, wait_thr|
        connout = EventMachine.watch(stdout, Popen3Reader, out, Fiber.current)
        connerr = EventMachine.watch(stderr, Popen3Reader, Tee.new(err, exception_buffer), Fiber.current)
        begin
          Tools.pids[wait_thr.pid] = cmd_string
          stdin.write(stdin_data) if stdin_data
          stdin.close
          connout.notify_readable = true
          connerr.notify_readable = true
          Fiber.yield until connout.closed? && connerr.closed?
          raise BuildError.new("#{cmd_string}\nKilled",dir) unless Tools.pids.delete(wait_thr.pid)
          raise BuildError.new("#{cmd_string}\n#{exception_buffer.string}",dir) unless wait_thr.value.exitstatus.zero?
        ensure
          Tools.pids.delete(wait_thr.pid)
          connout.detach
          connerr.detach
        end
      end
    end

    def popen3_inner(cmd, opts, &block)
      if cmd.is_a?(Array)
        Open3.popen3({}, *cmd, opts, &block)
      else
        Open3.popen3(cmd, opts, &block)
      end
    end
  end

  class Job
    class << self
      attr_writer :threads
    end

    def self.threads
      @threads || 100
    end

    attr_reader :name, :plan, :depends, :block, :include_depends, :file
    attr_accessor :exception
    def initialize(name, plan, depends, include_depends, &block)
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
      sources.each { |s| md5.update(s.to_s); }
      @file = File.join(plan.build_dir, "cache/#{@name}/#{md5.hexdigest}")
    end

    def id
      md5 = Digest::MD5.new
      md5.update(@plan.md5)
      md5.update(@plan.dir)
      md5.update(@name)
      md5.hexdigest
    end

    def last_result
      unless @last_result
        begin
          @last_result = File.open(@file, 'rb') { |f| Marshal.load(f) }
        rescue Errno::ENOENT # rubocop:disable HandleExceptions
        rescue StandardError
          puts "Removing #{@file}"
          File.delete(@file) if File.readable?(@file)
        end
        begin
          @headers = File.open(@file + '.dep', 'rb') { |f| Marshal.load(f) }
        rescue Errno::ENOENT
          @headers = nil
        rescue StandardError
          puts "Removing #{@file + '.dep'}"
          File.delete(@file + '.dep') if File.readable?(@file + '.dep')
        end
      end
      @last_result
    end

    def use_last_result
      @result = @last_result
    end

    def inspect
      "<Job @name=#{@name.inspect} @dir=#{@plan.dir} @depends=#{@depends.inspect} @result=#{@result.inspect}>"
    end

    def mtime
      File.mtime(@file)
    end

    def import(result, headers)
      @result = result
      @headers = {}
      headers.each do |key, _value|
        @headers[key] = true
      end
      save(@result)
    end

    def save(result)
      FileUtils.mkdir_p(File.dirname(@file))
      File.open(@file, 'wb') { |f| Marshal.dump(result, f) }
      File.open(@file + '.dep', 'wb') { |f| Marshal.dump(@headers, f) } if @headers && !@headers.empty?
      result
    end

    def result
      if @result.is_a?(Future)
        begin
          @result = @result.result
          @exception = nil
        rescue StandardError => e
          @exception = e
          raise e
        end
      end
      @result
    end

    def build(policy)
      begin
        policy.build(depends + include_depends)
      rescue StandardError => e
        @exception = e
        raise e
      end
      @result = Future.new(@name) do
        headers
        depends.map(&:result)
        result = @block.call(@headers)
        save(result)
      end
      return result if Job.threads == 1

      @result
    end

    def sources(result = nil)
      unless @sources
        @sources = {}
        @depends.each do |d|
          if d.is_a?(Job)
            d.sources(@sources)
          else
            @sources[d.to_s] = d
          end
        end
      end
      result ? result.merge!(@sources) : @sources.values
    end

    def headers(result = nil)
      unless @headers
        @headers = {}
        @depends.each do |d|
          d.headers(@headers) if d.is_a?(Job)
        end
      end
      result ? result.merge!(@headers) : @headers.keys
    end

    def to_s
      @name
    end

    def to_a
      [self]
    end

    def reset
      @result = nil
      @last_result= nil
      @depends.each do |d|
        d.reset if d.is_a?(Job)
      end
    end
  end

  class Plan
    BUILD_DIR = '.rmk'
    include Tools

    attr_accessor :md5
    def initialize(build_file_cache, file, md5)
      @build_file_cache = build_file_cache
      @file = file
      @dir = File.dirname(file)
      @md5 = md5
    end

    def self.file=(value)
      @dir = File.dirname(value)
    end

    def project(file)
      @build_file_cache.load(file, @dir)
    end

    def self.plugin(name)
      Kernel.require File.join(File.expand_path(File.dirname(File.dirname(__FILE__))), 'plugins', name + '.rb')
      include const_get(name.split('-').map { |string| string.capitalize }.join)
    end

    def job(name, depends, include_depends = [], &block)
      Job.new(name, self, depends, include_depends, &block)
    end

    def glob(pattern)
      Dir.glob(File.join(@dir, pattern))
    end

    attr_reader :dir

    def build_dir
      File.join(@dir, BUILD_DIR)
    end

    def file(name)
      return File.join(@dir, name) if name.is_a?(String)

      name.to_a.map { |x| File.join(@dir, x) }
    end

    def to_s
      @file
    end
  end

  class PlanCache
    include Tools
    def initialize
      @cache = {}
    end

    def load(file, dir = '.')
      case dir
      when %r{git@([^:]*):(.*)/([^#]*)(#.*|)}
        fragment = Regexp.last_match(4)
        path = Regexp.last_match(3).sub(/\.git$/, '')
        dir = git_pull(dir, File.join(RMK_DIR, path), fragment.empty? ? 'master' : fragment[1..-1])
      when %r{https{0,1}://}
        uri = URI.parse(dir)
        branch = uri.fragment || 'master'
        uri.fragment = nil
        dir = git_pull(uri.to_s, File.join(RMK_DIR, File.basename(uri.path).sub(/\.git$/, '')), branch)
      end
      file = File.expand_path(File.join(dir, file))
      file = File.join(file, 'build.rmk') if File.directory?(file)
      @cache[file] ||= load_inner(file)
    end

    def git_pull(remote, local, branch)
      info_file = local + '.yaml'
      info = {}
      if File.directory?(local)
        if File.readable?(info_file)
          info = YAML.safe_load(File.read(info_file))
          if info['branch'] != branch
            system("git checkout #{branch}", chdir: local)
            info['branch'] = branch
            File.write(info_file, YAML.dump(info))
          else
            system('git pull', chdir: local)
          end
        else
          system("git checkout #{branch}", chdir: local)
          info['branch'] = branch
          File.write(info_file, YAML.dump(info))
        end
      else
        FileUtils.mkdir_p(File.dirname(local))
        system("git clone --branch #{branch} #{remote} #{local}", chdir: File.dirname(local))
        info['branch'] = branch
        File.write(info_file, YAML.dump(info))
      end
      local
    end

    def load_inner(file)
      plan_class = Class.new(Plan)
      content = File.read(file)
      plan_class.file = file
      plan_class.module_eval(content, file, 1)
      MethodCache.new(plan_class.new(self, file, Digest::MD5.hexdigest(content)))
    end
  end

  class AlwaysBuildPolicy
    def build(jobs)
      jobs.each do |job|
        next unless job.is_a?(Job)

        job.build(self) unless job.result
      end
      jobs.map(&:result)
    end
  end


  class ModificationTimeBuildPolicy
    def initialize(readonly = false)
      @readonly = readonly
    end

    def cache(_job, &block)
      block.call
    end

    def build(jobs)
      jobs.each do |job|
        next unless job.is_a?(Job)

        next if job.result

        rebuild = true
        if job.last_result
          rebuild = false
          mtime = job.mtime
          (job.sources + job.headers).each do |d|
            dmtime = d.respond_to?(:mtime) ? d.mtime : File.mtime(d)
            next unless dmtime > mtime
            raise "Rebuilding #{job.name}(#{mtime}) because #{Tools.relative(d)}(#{dmtime}) is newer" if @readonly

            puts "Rebuilding #{job.name}(#{mtime}) because #{Tools.relative(d)}(#{dmtime}) is newer" if Rmk.verbose > 0
            rebuild = true
            break
          end
        else
          raise "Rebuilding #{job.name} because #{job.file} doesn't exist" if @readonly

          puts "Rebuilding #{job.name} because #{job.file} doesn't exist" if Rmk.verbose > 0
        end
        if rebuild
          cache(job) do
            job.build(self)
          end
        else
          job.use_last_result
        end
      end
      jobs.map(&:result)
    end
  end

  class LocalBuildPolicy < ModificationTimeBuildPolicy
    def initialize
      @depth = 0
      @child_build_policy = ModificationTimeBuildPolicy.new
    end

    def build(jobs)
      jobs.each do |job|
        next unless job.is_a?(Job)

        @depth += 1
        begin
          job.build(@depth > 1 ? self : @child_build_policy) unless job.result
        ensure
          @depth -= 1
        end
      end
      jobs.map(&:result)
    end
  end

  class CacheBuildPolicy < ModificationTimeBuildPolicy
    def initialize(url)
      @url = url
      @md5_cache = {}
    end

    def md5(file)
      @md5_cache[file] ||= begin
        Digest::MD5.hexdigest(File.open(file, 'rb', &:read).gsub(/\s+/, ''))
                           rescue Errno::ENOENT
                             '0000'
      end
    end

    def put(path, body)
      f = Fiber.current
      http = EventMachine::HttpRequest.new(File.join(@url, path)).put body: body
      http.callback { f.resume(http) }
      http.errback  { f.resume(http) }
      http = Fiber.yield
    end

    def get(path)
      f = Fiber.current
      http = EventMachine::HttpRequest.new(File.join(@url, path)).get
      http.callback { f.resume(http) }
      http.errback  { f.resume(http) }
      http = Fiber.yield
      code = http.response_header.status
      raise Errno::ENOENT, "File '#{path}' not found: #{code}" unless code == 200

      http.response
    end

    def cache(job, &block)
      sources = job.sources
      sources << job.plan.to_s

      id = Digest::MD5.new
      sources.sort.each do |k|
        id.update(k)
        id.update(md5(k))
      end
      id = id.hexdigest
      result = nil
      begin
        JSON.parse(get(File.join(job.name, id, 'index'))).each do |entries|
          entries.each do |hid, headers|
            found = true
            headers.each do |file, x|
              found &&= (md5(file) == x)
            end
            next unless found

            result = JSON.parse(get(File.join(job.name, id, hid + '.json')))['result']
            FileUtils.mkdir_p(File.dirname(result))
            File.open(result, 'wb') { |f| f.write(get(File.join(job.name, id, hid + '.bin'))) }
            puts("GET #{result}")
            job.import(result, headers)
            break
          end
        end
      rescue Errno::ENOENT # rubocop:disable HandleExceptions
      rescue StandardError => e
        warn e.message
        warn e.backtrace.join("\n")
      end
      return if job.result

      block.call
      headers = {}
      hid = Digest::MD5.new
      job.headers.sort.each do |k|
        hid.update(k)
        x = md5(k)
        headers[k] = x
        hid.update(x)
      end
      hid = hid.hexdigest
      return unless job.result.is_a?(String)

      put(File.join(job.name, id, hid + '.json'), { 'result' => job.result }.to_json)
      put(File.join(job.name, id, hid + '.bin'), File.open(job.result, 'rb', &:read))
      put(File.join(job.name, id, hid + '.dep'), { hid => headers }.to_json)
    end
  end

  class Controller
    attr_accessor :dir, :policy, :task

    def initialize
      @dir = Dir.getwd
      @policy = ModificationTimeBuildPolicy.new
      @task = 'all'
    end

    def run(policy: nil, jobs: nil)
      policy ||= @policy
      result = 0
      EventMachine.run do
        Fiber.new do
          jobs ||= load_jobs
          jobs.each(&:reset)
          begin
            item = policy.build(jobs)
            Rmk.stdout.write item.result.inspect if Rmk.verbose > 0 # rubocop:disable Metrics/LineLength, Style/NumericPredicate
            Rmk.stdout.write "Build OK\n"
          rescue BuildError => e
            Rmk.stderr.write(e.message + "\n")
            Rmk.stderr.write(e.backtrace.join("\n")) if Rmk.verbose > 0 # rubocop:disable Metrics/LineLength, Style/NumericPredicate
            Rmk.stdout.write "Build Failed in #{e.dir}\n"
            result = 1
          rescue StandardError => e
            Rmk.stderr.write(e.message + "\n")
            Rmk.stderr.write(e.backtrace.join("\n"))
            Rmk.stdout.write "Build Failed\n"
            result = 1
          end
          yield jobs if block_given?
        end.resume
      end
      result
    end

    def load_jobs
      build_file_cache = PlanCache.new
      build_file = build_file_cache.load('build.rmk', @dir)
      build_file.send(@task.intern)
    end
  end
end
