require 'fileutils'
require 'tmpdir.rb'

module Cpp
  class ObjectFile < String
    attr_reader :includes
    def initialize(file)
      super(file)
      @includes = []
    end
    def inspect()
     "Cpp::ObjectFile:#{super.to_s}"
    end
    def mtime
      @mtime ||= File.mtime(self)
    end
  end

  class Archive < String
    attr_reader :includes
    def initialize(name)
      super(name)
      @includes = []
    end
    def inspect()
     "Cpp::Archive:#{super.to_s}"
    end
    def mtime
      @mtime ||= File.mtime(self)
    end
  end
  
  class Include
    attr_reader :includes
    def initialize(dirs,options)
      @includes = dirs.map{ | x |  "-I#{x}" }
    end
    def inspect()
     "<Cpp::Include: @includes=#{@includes.inspect}>"
    end
    def mtime
      @mtime ||= File.mtime(self)
    end
    def result
      return self
    end
  end
end

module Gnu

  include Rmk::Tools
  
  TARGET = "i486-linux"
  
  
  def inc(dirs, options = {})
      return [ Cpp::Include.new(dirs, options ) ]
  end

  def cc(files,depends, options = {}) 
    result = []
    return inc([dir],options) if files.empty?
    local_includes = files.map{ | x | "-I" + File.dirname(x)}.uniq
    files.each do | cpp |
      header = []
      basename, suffix  = File.basename(cpp.to_s).split(".")
      result << work_item(basename + ".o",[cpp],depends) do | hidden |
        includes = [] 
        depends.each do | d |
          d = d.result
          includes.concat(d.includes) if d.respond_to?(:includes)
        end
        includes.uniq!
        target_dir = File.join(build_dir,TARGET)
        ofile = File.join(target_dir,basename + ".o")
        dfile = File.join(target_dir,basename + ".d")
        FileUtils.mkdir_p(target_dir)
        system("gcc -x c++ #{options[:flags].to_s} #{local_includes.join(" ")} -o #{ofile} #{includes.join(" ")} -MD -c #{cpp.result}")
        content = File.read(dfile)
        File.delete(dfile)
        content.gsub!(/\b[A-Z]:\//i,"/")
        content.gsub!(/^[^:]*:/,"")
        content.gsub!(/\\$/,"")
        content = content.split()
        content.shift()
        content.each{ | h | hidden[h] = true }
        result = Cpp::ObjectFile.new(ofile)
        result.includes.concat(local_includes)
        result.includes.concat(options[:flags].to_s.split().select{ | x | x[0,2] == "-I"} )
        result.includes.concat(includes).uniq!
        result
      end
    end
    result
  end
  
  def ar(name,depends, options = {}) 
    result = work_item("lib" + name + ".a",depends) do
      target_dir = File.join(build_dir,TARGET)
      FileUtils.mkdir_p(target_dir)
      lib = Cpp::Archive.new(File.join(target_dir, "lib" + name+".a"))
      objects = depends.map{ | x | x.result }
   	  objects.each do | d |
      	lib.includes.concat(d.includes) if d.respond_to?(:includes)
    	end
      objects = objects.delete_if{ | x | x.is_a?(Cpp::Include) }
    	lib.includes.uniq!
      cfile = File.join(target_dir,name + ".cmd")
      File.open(cfile,"w") { | f | f.write(objects.join(" ")) }
      FileUtils.rm_f(lib)
      system("ar -cr  #{lib} #{objects.join(" ")}  ")
      lib
    end
    [ result ]
  end
  
  def ld(name,depends, options = {}) 
    result = work_item(name,depends) do 
      target_dir = File.join(build_dir,TARGET)
      FileUtils.mkdir_p(target_dir)
      ofile = File.join(target_dir,name)
      objects = depends.map{ | x | x.result }
      libs = objects.select{ | o | o[-2,2] == ".a" }
      objects = objects - libs
      start_group = "-Wl,--start-group"
      end_group = "-Wl,--end-group"
      if RUBY_PLATFORM =~ /darwin/
      	start_group = end_group = ""
      end
      libflags = libs.map{| a | "-L#{File.dirname(a)} -l#{File.basename(a,".a")[3..-1]}"}.join(" ")
      system("g++ #{objects.join(" ")} #{start_group} #{libflags} #{end_group}  -o #{ofile} ")
      ofile
    end
    [ result ]
  end
end
