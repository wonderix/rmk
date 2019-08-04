# frozen_string_literal: true

require 'fileutils'
require 'tmpdir.rb'

module Cpp
  class ObjectFile < String
    attr_reader :flags
    def initialize(file)
      super(file)
      @flags = []
    end

    def inspect
      "Cpp::ObjectFile:#{super}"
    end

    def mtime
      @mtime ||= File.mtime(self)
    end
  end

  class Archive < String
    attr_reader :flags
    def initialize(name)
      super(name)
      @flags = []
    end

    def inspect
      "Cpp::Archive:#{super} @flags=#{@flags.inspect}"
    end

    def mtime
      @mtime ||= File.mtime(self)
    end

    def name
      File.basename(self, '.a')[3..-1]
    end
  end

  class SharedLibrary < String
    attr_reader :flags
    def initialize(name, flags)
      super(name)
      @flags = flags
    end

    def inspect
      "Cpp::SharedLibrary:#{super} @flags=#{@flags.inspect}"
    end

    def mtime
      @mtime ||= File.mtime(self)
    end

    def name
      File.basename(self, '.so')[3..-1]
    end
  end

  class Include
    attr_reader :flags
    def initialize(flags)
      @flags = flags
    end

    def inspect
      "<Cpp::Include: @flags=#{@flags.inspect}>"
    end

    def mtime
      @mtime ||= Time.at(0)
    end

    def to_s
      @flags.join(' ')
    end

    def result
      self
    end
  end
end

module Gnu
  include Rmk::Tools

  TARGET = 'i486-linux'

  def inc(dirs, _ = {})
    [Cpp::Include.new(dirs.map { |x| "-I#{x}" })]
  end

  def cc(files, depends, options = {})
    return inc([dir], options) if files.empty?

    local_includes = files.map { |x| '-I' + File.dirname(x) }.uniq
    files.map do |cpp|
      basename, = File.basename(cpp.to_s).split('.')
      job(basename + '.o', cpp, depends) do |cpp, depends, implicit_dependencies| # rubocop:disable Lint/ShadowingOuterLocalVariable
        flags = depends.select { |d| d.respond_to?(:flags) }.flat_map(&:flags).uniq
        target_dir = File.join(build_dir, TARGET)
        ofile = File.join(target_dir, basename + '.o')
        dfile = File.join(target_dir, basename + '.d')
        FileUtils.mkdir_p(target_dir)
        lang = cpp[-2, 2] == '.c' ? 'c' : 'c++'
        system("gcc -x #{lang} #{options[:flags]} #{local_includes.join(' ')} -fPIC -o #{ofile} #{flags.join(' ')} -MD -c #{cpp}")
        content = File.read(dfile)
        File.delete(dfile)
        content.gsub!(%r{\b[A-Z]:\/}i, '/')
        content.gsub!(/^[^:]*:/, '')
        content.gsub!(/\\$/, '')
        content = content.split
        content.shift
        content.each { |h| implicit_dependencies[h] = true }
        result = Cpp::ObjectFile.new(ofile)
        result.flags.concat(local_includes)
        result.flags.concat(options[:flags].to_s.split)
        result.flags.concat(flags).uniq!
        result
      end
    end
  end

  def ar(name, depends, _options = {})
    job('lib' + name + '.a', depends) do |depends| # rubocop:disable Lint/ShadowingOuterLocalVariable
      target_dir = File.join(build_dir, TARGET)
      FileUtils.mkdir_p(target_dir)
      lib = Cpp::Archive.new(File.join(target_dir, 'lib' + name + '.a'))
      objflags = []
      depends.each do |d|
        lib.flags.concat(d.flags) if d.respond_to?(:flags)
        case d
        when Cpp::ObjectFile
          objflags << d
        end
      end
      lib.flags.uniq!
      FileUtils.rm_f(lib)
      system("ar -cr  #{lib} #{objflags.join(' ')}  ")
      lib
    end
  end

  def ld(name, depends, _options = {})
    job(name, depends) do |depends| # rubocop:disable Lint/ShadowingOuterLocalVariable
      target_dir = File.join(build_dir, TARGET)
      FileUtils.mkdir_p(target_dir)
      ofile = File.join(target_dir, name)
      libflags = []
      objflags = []
      depends.each do |d|
        case d
        when Cpp::Archive, Cpp::SharedLibrary
          libflags << "-Wl,-rpath,#{File.dirname(d)}" if d.is_a?(Cpp::SharedLibrary)
          libflags << "-L#{File.dirname(d)}"
          libflags << "-l#{d.name}"
        when Cpp::ObjectFile
          objflags << d
        end
      end
      start_group = '-Wl,--start-group'
      end_group = '-Wl,--end-group'
      start_group = end_group = '' if RUBY_PLATFORM =~ /darwin/
      system("g++ #{objflags.join(' ')} #{start_group} #{libflags.join(' ')} #{end_group}  -o #{ofile} ")
      ofile
    end
  end

  def ld_shared(name, depends, _options = {})
    name = 'lib' + name + '.so'
    job(name, depends) do |depends| # rubocop:disable Lint/ShadowingOuterLocalVariable
      target_dir = File.join(build_dir, TARGET)
      FileUtils.mkdir_p(target_dir)
      libflags = []
      objflags = []
      flags = []
      depends.each do |d|
        flags.concat(d.flags) if d.respond_to?(:flags)
        case d
        when Cpp::Archive, Cpp::SharedLibrary
          libflags << "-Wl,-rpath,#{File.dirname(d)}" if d.is_a?(Cpp::SharedLibrary)
          libflags << "-L#{File.dirname(d)}"
          libflags << "-l#{d.name}"
        when Cpp::ObjectFile
          objflags << d
        end
      end
      lib = Cpp::SharedLibrary.new(File.join(target_dir, name), flags.uniq)
      start_group = '-Wl,--start-group'
      end_group = '-Wl,--end-group'
      start_group = end_group = '' if RUBY_PLATFORM =~ /darwin/
      system("g++ -shared -Wl,-soname=#{name} #{objflags.join(' ')} #{start_group} #{libflags.join(' ')} #{end_group}  -o #{lib} ")
      lib
    end
  end
end
