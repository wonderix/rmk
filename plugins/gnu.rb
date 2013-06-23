require 'fileutils'

class CppFileArchive
  attr_accessor :objects, :includes
  def initialize()
    @objects = []
    @includes = []
  end
  def to_a()
    @objects
  end
  def to_s()
    @objects.to_s
  end
  def inspect()
     "CppFileArchive:" + @objects.inspect
  end
  def mtime()
    mtime = Time.at(0)
    @objects.each do | o |
      m = File.mtime(o)
      mtime = m if m > mtime
    end
    mtime
  end
  def value()
  	@objects
  end
end

class CppArArchive
  attr_accessor :includes
  def initialize(name)
    @name = name
    @includes = []
  end
  def to_a()
    [ @name ]
  end
  def to_s()
    @name
  end
  def inspect()
    "CppArArchive:" + @name.inspect
  end
  def mtime()
  	File.mtime(@name)
  end
  def value()
  	@name
  end
end

module Gnu

  include BuildTools
  
  TARGET = "i486-linux"

  def cc(files,depends, options = {}) 
    depends = depends.uniq
    result = CppFileArchive.new
    includes = [] 
    depends.each do | d |
      includes.concat(d.includes) if d.respond_to?(:includes)
    end
    includes.uniq!
    futures = []
    files.each do | cpp |
      futures << build_cache([cpp]) do | depends |
        basename, suffix  = File.basename(cpp).split(".")
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
        depends.concat(content)
        ofile
      end
    end
    result.objects.concat(futures.map { | f | f.value })
    result.includes.concat(files.map{ | x | "-I" + File.dirname(x)}.uniq)
    result.includes.push("-I" + dir()) if files.empty?
    result.includes.concat(includes).uniq!
    [ result ]
  end
  
  def ar(name,depends, options = {}) 
    build_cache(depends) do
      target_dir = File.join(build_dir,TARGET)
      FileUtils.mkdir_p(target_dir)
      lib = CppArArchive.new(File.join(target_dir,name+".a"))
    	depends.each do | d |
      	lib.includes.concat(d.includes) if d.respond_to?(:includes)
    	end
    	lib.includes.uniq!
      objects = []
      depends.each { | d | objects.concat(d.to_a) }
      cfile = File.join(target_dir,name + ".cmd")
      File.open(cfile,"w") { | f | f.write(objects.join(" ")) }
      system("ar -cr  #{lib} #{objects.join(" ")}  ")
      [ lib ]
    end.value
  end
  
  def ld(name,depends, options = {}) 
    build_cache(depends) do
      target_dir = File.join(build_dir,TARGET)
      FileUtils.mkdir_p(target_dir)
      ofile = File.join(target_dir,name)
      objects = []
      depends.each { | d | objects.concat(d.to_a) }
      cfile = File.join(target_dir,name + ".cmd")
      File.open(cfile,"w") { | f | f.write(objects.join(" ")) }
      system("g++ @#{cfile} -o #{ofile} ")
      ofile
    end.value
  end
end
