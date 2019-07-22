# frozen_string_literal: true

require_relative '../lib/rmk.rb'

include Rmk::Tools

def dir
  File.dirname(__FILE__)
end

describe File, '#relative_path_from' do
  it 'should caclulate correct path' do
    rel = File.relative_path_from('/home/kramer/sources/eddi/EDDI3/common/', '/home/kramer/sources/eddi/EDDI3/PIRcpt')
    expect(rel).to eq('../common')
    rel = File.relative_path_from('/home/kramer/sources/eddi/EDDI3/', '/home/kramer/sources/eddi/EDDI3/PIRcpt')
    expect(rel).to eq('..')
  end
end

describe Rmk::Tools do
  around(:each) do |example|
    EventMachine.run do
      Fiber.new do
        example.run
        EventMachine.stop
      end.resume
    end
  end

  describe '#system' do

    it 'return stdout' do
      expect(system('echo Hello World')).to eq("Hello World\n")
    end

    it 'return stderr in exception' do
      expect { system('ruby -e "STDERR.puts(%q(Hello World)); exit(1);"') }.to raise_error(Exception, /Hello World/)
    end

    it 'should raise exception in case of exit code non equal to zero' do
      expect { system('exit 1') }.to raise_error(Exception)
    end
  end

  Rmk::Tools.trace = false

  describe Rmk::Tools do
    it 'return stdout' do
      out = StringIO.new
      popen3('echo Hello World', out: out)
      expect(out.string).to eq("Hello World\n")
    end

    it 'return stderr' do
      err = StringIO.new
      popen3(['ruby', '-e', 'STDERR.puts("Hello World")'], err: err)
      expect(err.string).to eq("Hello World\n")
    end

    it 'changes the directory' do
      out = StringIO.new
      popen3('pwd', out: out, chdir: '/')
      expect(out.string).to eq("/\n")
    end

    it 'accepts stdin_data' do
      out = StringIO.new
      popen3('cat', out: out, stdin_data: "Hello World\n")
      expect(out.string).to eq("Hello World\n")
    end

    it 'should raise exception in case of exit code non equal to zero' do
      expect { popen3('exit 1') }.to raise_error(Exception)
    end
  end
end
