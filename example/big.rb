require 'fileutils'

class Project
  attr_reader :dir
  def initialize(dir,depends,size)
    @dir = dir
    FileUtils.mkdir_p(dir)
    for i in 0..size
      File.open("#{dir}/test_#{i}.cpp","w") do | f |
        f.puts("#include <test_#{i}.h>")
        f.puts("void test_#{i}() {")
        f.puts("}")
      end
      File.open("#{dir}/test_#{i}.h","w") do | f |
        f.puts("void test_#{i}();")
      end
    end
    File.open("#{dir}/build.rmk","w") do | f |
      f.puts("plugin 'gnu'")
      f.puts("def compile_cpp()")
      f.puts("  dependencies = []")
      depends.each do | p |
        f.puts("  dependencies += project(\"../../#{p.dir}\").compile_cpp")
      end
      f.puts("  cc(glob(\"*.cpp\"),dependencies)")
      f.puts("end")
    end

  end
end


projects = []

for i in 0..50 
  projects << Project.new("big/project_#{i}",projects,100)
end

File.open("big/build.rmk","w") do | f |
  f.puts("plugin 'gnu'")
  f.puts("def all()")
  f.puts("  project(\"../#{projects.last.dir}\").compile_cpp")
  f.puts("end")
end

