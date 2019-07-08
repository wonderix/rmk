require 'stringio'

module Go

  include Rmk::Tools
  
  def go_build(name,package, mod: "readonly", depends: [], goos: nil)
    result = []
    result << job(name,go_files(package) + depends ) do | hidden |
      output = goos ? File.join(build_dir,goos,name) : File.join(build_dir,name)
      ENV['GOOS'] = goos if goos
      begin
        system("go build -mod=#{mod} -o #{output} #{package}")
      rescue
        ENV.delete('GOOS') if goos
      end
      output
    end
    result
  end


  def go_lint(package)
    result = []
    files =  go_files(package)
    files.map do | file |
      name = File.basename(file,".go") + ".lint"
      job(name,[file]) do | hidden |
        output = File.join(build_dir,name)
        File.write(output,system("golint -set_exit_status #{file}"))
        output
      end
    end
  end

  def go_coverage(package,limits, mod: "readonly")
    result = []
    result << job("coverage",go_files(package,true)) do | hidden |
      output = File.join(build_dir,"coverage")
      coverage = StringIO.new(system("go test -cover -mod=#{mod} #{package}"))
      while line = coverage.gets()
        if line =~ /ok\s+(\S+)\s+.*coverage:\s+(\d+\.\d+)%/
          percent = $2.to_f
          pkg = $1.sub(/[^\/]*\/[^\/]*\/[^\/]*\/*/,'')
          pkg = "." if pkg.empty?
          limit = limits[pkg] || 0.0
          if percent < limit
            raise "Coverage for package #{pkg} (#{percent}%) fallen below #{limit}%"
          end
        end
      end
      output
    end
    result
  end

  def go_files(package,include_tests = false)
    result =  package.end_with?("/...")  ? Dir.glob(File.join(dir,"#{package.sub("...","")}**/*.go")) : Dir.glob(File.join(dir,"#{package}/*.go"))
    result = result.delete_if{|x| x.end_with?("_test.go")} unless include_tests 
    return result
  end

end