# frozen_string_literal: true

require 'fileutils'

class Project
  attr_reader :dir
  attr_reader :name
  def initialize(dir, name, depends, size)
    @name = name
    @dir = File.join(dir, name)
    FileUtils.mkdir_p(@dir)
    (0...size).each do |i|
      File.open("#{@dir}/test_#{name}_#{i}.cpp", 'w') do |f|
        f.puts("#include <test_#{name}_#{i}.h>")
        f.puts('#include <stdio.h>')
        f.puts("int test_#{name}_#{i}(int depth) {")
        f.puts('  for ( int i = 0 ; i < depth; i++) printf("  ");')
        f.puts("  puts(\"test_#{name}_#{i}\");")
        depends.each do |p|
          (0...1).each do |j|
            f.puts("  test_#{p.name}_#{j}(depth+1);")
          end
        end
        f.puts('  return 0;')
        f.puts('}')
      end
      File.open("#{@dir}/test_#{name}_#{i}.h", 'w') do |f|
        f.puts("#ifndef TEST_#{name.upcase}_#{i}")
        f.puts("#define TEST_#{name.upcase}_#{i}")
        depends.each do |p|
          (0...1).each do |j|
            f.puts("#include <test_#{p.name}_#{j}.h>")
          end
        end
        f.puts("int test_#{name}_#{i}(int depth);")
        f.puts('#endif')
      end
    end
    File.open("#{@dir}/build.rmk", 'w') do |f|
      f.puts("plugin 'gnu'")
      f.puts('def compile_cpp()')
      f.puts('  dependencies = []')
      depends.each do |p|
        f.puts("  dependencies << project(\"../#{p.name}\").compile_cpp")
      end
      f.puts("  ar(\"#{name}\",cc(glob(\"*.cpp\"),dependencies))")
      f.puts('end')
    end
    File.open("#{@dir}/SConstruct", 'w') do |f|
      f.puts("Decider('timestamp-newer')")
      f.puts("Library('foo',Glob('*.cpp'), CCFLAGS='-I. -I#{@name} #{depends.map { |p| '-I' + p.name }.join(' ')}') ")
    end
  end
end

projects = []

count = ARGV[0] ? ARGV[0].to_i : 50
files = ARGV[1] ? ARGV[1].to_i : 100
(0...count).each do |i|
  projects << Project.new('big', "project_#{i}", projects, files)
end

p = projects.last
File.open('big/main.cpp', 'w') do |f|
  f.puts("#include <test_#{p.name}_0.h>")
  f.puts('int main(int argc, char** argv) {')
  f.puts(" return test_#{p.name}_0(0);")
  f.puts('}')
end

File.open('big/build.rmk', 'w') do |f|
  f.puts("plugin 'gnu'")
  f.puts('def all()')
  f.puts('  dependencies = []')
  projects.each do |p|
    f.puts("  dependencies << project(\"#{p.name}\").compile_cpp")
  end
  f.puts('  ld("main",cc(glob("*.cpp"),dependencies)+dependencies)')
  f.puts('end')
end

File.open('big/SConstruct', 'w') do |f|
  f.puts("SConscript([#{projects.map { |p| "'" + p.name + "/SConstruct'" }.join(', ')}]) ")
end
