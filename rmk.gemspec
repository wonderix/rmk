
Gem::Specification.new 'rmk', '0.1.0' do |s|
  s.description       = "rmk is a fast building tool"
  s.summary           = "building tool"
  s.authors           = ["Ulrich Kramer"]
  s.email             = "wonderix@googlemail.com"
  s.homepage          = "https://github.com/wonderix/rmk"
  s.files             = `git ls-files bin lib plugins`.split("\n") + %w(README.md LICENSE)
  s.test_files        = s.files.select { |p| p =~ /^spec\/..rb/ }
  s.extra_rdoc_files  = s.files.select { |p| p =~ /^README/ }
  s.add_dependency 'sinatra', '~> 1.3'
  s.add_dependency 'eventmachine', '~> 1.0'
  s.add_dependency 'em-http-request', '~> 1.0'
  s.add_dependency 'thin', '~> 1.0'
  s.add_dependency 'slim'
  s.add_dependency 'semantic'
  s.require_path          = "lib"
  s.bindir                = "bin"
  s.license               = "LICENSE"
  s.executables        += %w(rmk rmksrv)
  s.default_executable = 'bin/rmk'
  s.required_ruby_version = '>= 1.9.0'
end