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

describe Rmk::Tools, '#system' do
  it 'return stdout' do
    EventMachine.run do
      Fiber.new do
        expect(system('echo Hello World')).to eq("Hello World\n")
        EventMachine.stop
      end.resume
    end
  end
  it 'return stderr in exception' do
    EventMachine.run do
      Fiber.new do
        expect { system('ruby -e "STDERR.puts(%q(Hello World)); exit(1);"') }.to raise_error(Exception, /Hello World/)
        EventMachine.stop
      end.resume
    end
  end
  it 'should raise exception in case of exit code non equal to zero' do
    EventMachine.run do
      Fiber.new do
        expect { system('exit 1') }.to raise_error(Exception)
        EventMachine.stop
      end.resume
    end
  end
end

EventMachine.kqueue = true

describe Rmk::Tools, '#popen3' do
  it 'return stdout' do
    EventMachine.run do
      Fiber.new do
        out = StringIO.new
        popen3('echo Hello World', out: out)
        expect(out.string).to eq("Hello World\n")
        EventMachine.stop
      end.resume
    end
  end
  it 'return stderr' do
    EventMachine.run do
      Fiber.new do
        err = StringIO.new
        popen3(['ruby', '-e', 'STDERR.puts("Hello World")'], err: err)
        expect(err.string).to eq("Hello World\n")
        EventMachine.stop
      end.resume
    end
  end
  it 'changes the directory' do
    EventMachine.run do
      Fiber.new do
        out = StringIO.new
        popen3('pwd', out: out, chdir: '/')
        expect(out.string).to eq("/\n")
        EventMachine.stop
      end.resume
    end
  end
  it 'accepts stdin_data' do
    EventMachine.run do
      Fiber.new do
        out = StringIO.new
        popen3('cat', out: out, stdin_data: "Hello World\n")
        expect(out.string).to eq("Hello World\n")
        EventMachine.stop
      end.resume
    end
  end
  it 'should raise exception in case of exit code non equal to zero' do
    EventMachine.run do
      Fiber.new do
        expect { popen3('exit 1') }.to raise_error(Exception)
        EventMachine.stop
      end.resume
    end
  end
end
