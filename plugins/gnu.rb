require 'fileutils'


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
end

module Gnu

  include Rmk::Tools
  
  TARGET = "i486-linux"

  def cc(files,depends, options = {}) 
    result = []
    local_includes = files.empty? ? [ "-I#{dir}" ]  : files.map{ | x | "-I" + File.dirname(x)}.uniq
    files.each do | cpp |
      header = []
      basename, suffix  = File.basename(cpp).split(".")
      result << build_cache(basename + ".o",[cpp],depends) do | depends, hidden |
        includes = [] 
        depends.each do | d |
          includes.concat(d.includes) if d.respond_to?(:includes)
        end
        includes.uniq!
        target_dir = File.join(build_dir,TARGET)
        ofile = File.join(target_dir,basename + ".o")
        dfile = File.join(target_dir,basename + ".d")
        FileUtils.mkdir_p(target_dir)
        system("gcc -x c++ #{options[:flags].to_s} -I#{dir} -o #{ofile} #{includes.join(" ")} -MD -c #{cpp}")
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
        result.includes.concat(includes).uniq!
        result
      end
    end
    result
  end
  
  def ar(name,depends, options = {}) 
    result = build_cache("lib" + name + ".a",depends) do | objects |
      target_dir = File.join(build_dir,TARGET)
      FileUtils.mkdir_p(target_dir)
      lib = Cpp::Archive.new(File.join(target_dir, "lib" + name+".a"))
    	objects.each do | d |
      	lib.includes.concat(d.includes) if d.respond_to?(:includes)
    	end
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
    result = build_cache(name,depends) do | objects |
      target_dir = File.join(build_dir,TARGET)
      FileUtils.mkdir_p(target_dir)
      ofile = File.join(target_dir,name)
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
