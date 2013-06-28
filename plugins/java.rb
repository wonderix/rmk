require 'tempfile'
require 'fileutils'

module Java

  include Rmk::Tools
  
  def javac(files,jarfiles, options = {})
    result = work_item("classes",files+jarfiles) do
      classes_dir = File.join(build_dir(),"classes")
      FileUtils.rm_rf(classes_dir)
      FileUtils.mkdir_p(classes_dir)
      jarfiles = jarfiles.map{ | j | j.result}
      files = files.map{ | j | j.result}
      system("javac -cp #{jarfiles.join(":")} -d #{classes_dir} #{files.join(" ")}")
      Dir.glob(File.join(classes_dir,"**/*.class"))
    end
    [ result ]
  end
  
  def jar(name,classfiles, resourcefiles = [], options= {})
    result = work_item(name + ".jar",classfiles+resourcefiles) do
      lib_dir = File.join(build_dir,"lib");
      result = File.join(lib_dir,name + ".jar")
      classes_dir = File.join(build_dir(),"classes")
      FileUtils.mkdir_p(lib_dir)
      classfiles = classfiles.map{ | j | j.result}
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
    end
    [ result ]
  end
  
end
