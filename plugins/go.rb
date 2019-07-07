module Go


  def go_build(name,package)
    result = []
    result << job(name,Dir.glob("#{package}/**/*.go")) do | hidden |
      output = File.join(build_dir,name)
      system("go build -v -o #{output} #{package}/...")
      output
    end
    result
  end

end