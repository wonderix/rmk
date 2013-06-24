require 'tempfile'
require 'fileutils'

module Java

  include Rmk::Tools
  
  def javac(files,jarfiles, options = {})
    build_cache(files+jarfiles) do
      classes_dir = File.join(build_dir(),"classes")
      FileUtils.rm_rf(classes_dir)
      FileUtils.mkdir_p(classes_dir)
      system("javac -cp #{jarfiles.join(":")} -d #{classes_dir} #{files.join(" ")}")
      Dir.glob(File.join(classes_dir,"**/*.class"))
    end.value()
  end
  
  def jar(name,classfiles, resourcefiles = [], options= {})
    lib_dir = File.join(build_dir,"lib");
    result = File.join(lib_dir,name + ".jar")
    build_cache(classfiles+resourcefiles) do
      classes_dir = File.join(build_dir(),"classes")
      FileUtils.mkdir_p(lib_dir)
      file = Tempfile.new('jar')
      begin
        classfiles.each do | cls |
          file.puts("-C #{classes_dir} #{File.relative_path_from(cls,classes_dir) }")
        end
        file.close
        system("jar cf #{result} @#{file.path}")
      ensure
        # file.unlink
      end
      [ result ]
    end.value()
  end
  
end
