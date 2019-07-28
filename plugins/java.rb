# frozen_string_literal: true

require 'tempfile'
require 'fileutils'

# rubocop:disable Documentation

module Java
  include Rmk::Tools

  def javac(files, jarfiles, _options = {})
    job('classes', files, jarfiles) do
      classes_dir = File.join(build_dir, 'classes')
      FileUtils.rm_rf(classes_dir)
      FileUtils.mkdir_p(classes_dir)
      jarfiles = jarfiles.to_a.map(&:result)
      files = files.map(&:result)
      system("javac -cp #{jarfiles.join(':')} -d #{classes_dir} #{files.join(' ')}")
      Dir.glob(File.join(classes_dir, '**/*.class'))
    end
  end

  def jar(name, classfiles, resourcefiles = [], _options = {})
    job(name + '.jar', classfiles, resourcefiles) do
      lib_dir = File.join(build_dir, 'lib')
      result = File.join(lib_dir, name + '.jar')
      classes_dir = File.join(build_dir, 'classes')
      FileUtils.mkdir_p(lib_dir)
      classfiles = classfiles.to_a.map(&:result).flatten
      file = Tempfile.new('jar')
      classfiles.each do |cls|
        file.puts("-C #{classes_dir} #{File.relative_path_from(cls, classes_dir)}")
      end
      file.close
      system("jar cf #{result} @#{file.path}")
      result
    end
  end
end
