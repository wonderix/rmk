module Java

  def javac(files,jarfiles, options = {})
    build_cache(files+jarfiles) do
      classes_dir = File.join(build_dir(),"classes")
      FileUtils.rm_rf(classes_dir)
      FileUtils.mkdir_p(classes_dir)
      system("javac -cp #{jarfiles.join(":")} -d #{classes_dir} #{files}")
      Dir.glob(File.join(classes_dir,"**/*.class"))
    end
  end
  def jar(name,classfiles, resourcefiles = [], options= {})
    build_cache(classfiles+resourcefiles) do
      classes_dir = File.join(build_dir(),"classes")
      lib_dir = File.join(build_dir,"lib");
      result = File.join(lib_dir,name + ".jar")
      FileUtils.mkdir_p(lib_dir)
      system("jar cf #{result} -C #{classes_dir} #{classfiles.map{ | x | File.relative_path_from(x,classes_dir)}.join(" ")}")
      [ result ]
    end
  end
end
