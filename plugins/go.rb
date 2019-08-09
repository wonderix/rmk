# frozen_string_literal: true

require 'stringio'

ENV.delete('GOOS')
ENV.delete('GOFLAGS')
ENV.delete('GO111MODULE')

module Go
  include Rmk::Tools

  def go_build(name, package, mod: 'readonly', depends: [], goos: nil)
    name = goos ? File.join(goos, name) : name
    files = go_files(package)
    job('go/' + name, files, depends) do |files, depends, implicit_dependencies| # rubocop:disable Lint/ShadowingOuterLocalVariable
      output = File.join(build_dir, name)
      ENV['GOOS'] = goos if goos
      begin
        system("go build -mod=#{mod} -o #{output} #{package}")
        go_hidden(files, package, implicit_dependencies)
      ensure
        ENV.delete('GOOS') if goos
      end
      output
    end
  end

  def go_check_fmt(package)
    go_files(package).map do |file|
      job('go/check_fmt/' + File.basename(file, '.go'), file) do |file|  # rubocop:disable Lint/ShadowingOuterLocalVariable
        Rmk.stdout.write("gofmt -l #{file}\n")
        stdout = StringIO.new(capture2("gofmt -l #{file}"))
        if (stdout.gets)
          raise Rmk::BuildError.new("gofmt found issues", file)
        end
      end
    end
  end

  def go_lint(package)
    go_files(package).map do |file|
      job('go/lint/' + File.basename(file, '.go'), file) do |file|  # rubocop:disable Lint/ShadowingOuterLocalVariable
        system("golint -set_exit_status #{file}")
      end
    end
  end

  def go_coverage(package, min_coverage, min_coverage_per_package: {}, mod: 'readonly')
    files = go_files(package, true)
    job('go/coverage', files) do |files, implicit_dependencies| # rubocop:disable Lint/ShadowingOuterLocalVariable
      output = File.join(build_dir, 'coverage')
      Rmk.stdout.write("go test -cover -mod=#{mod} #{package}\n")
      coverage = StringIO.new(capture2("go test -cover -mod=#{mod} #{package}"))
      while (line = coverage.gets)
        next unless line =~ /ok\s+(\S+)\s+.*coverage:\s+(\d+\.\d+)%/

        percent = Regexp.last_match(2).to_f
        pkg = Regexp.last_match(1)
        pkg = '.' if pkg.empty?
        limit = min_coverage_per_package[pkg] || min_coverage
        raise Rmk::BuildError.new("Coverage for package '#{pkg}' is too low (#{percent}%<#{limit}%)", pkg) if percent < limit
        Rmk.stdout.write("#{percent}% #{pkg}\n")
      end
      go_hidden(files, package, implicit_dependencies)
      output
    end
  end

  private

  def go_files(package, include_tests = false)
    result = Dir.glob("#{package.sub('/...', '/**')}/*.go")
    result = result.delete_if { |x| x.end_with?('_test.go') } unless include_tests
    result
  end

  def go_hidden(go_files, package, implicit_dependencies)
    path, dir = capture2("go list -m -f '{{ .Path }} {{ .Dir }}'").split(/\s+/)
    known_dependencies = go_files.map { |f| [File.dirname(f).sub(dir, path), true] }.to_h
    capture2(%q(go list -f '{{ join .Deps  "\n"}}' ) + package).split("\n").each do |dep|
      if dep.start_with?(path) && !known_dependencies.include?(dep)
        known_dependencies[dep] = true
        Dir.glob("#{dep.sub(path, dir)}/*.go").each { |g| implicit_dependencies[g] = true }
      end
    end
  end
end
