# frozen_string_literal: true

require_relative '../lib/rmk.rb'

class PlanMock
  def md5
    'md5'
  end

  def build_dir
    '/tmp/rmk'
  end

  def dir
    '/tmp/rmk'
  end
end

PLAN = PlanMock.new

describe Rmk::Job do
  around(:each) do |example|
    EventMachine.run do
      Fiber.new do
        example.run
        FileUtils.rm_rf(PLAN.build_dir)
        EventMachine.stop
      end.resume
    end
  end

  it 'arguments are passed' do
    job = Rmk::Job.new('job1', PLAN, [1, 2, 3, 4]) do |a, b, c, d|
      expect(a).to be 1
      expect(b).to be 2
      expect(c).to be 3
      expect(d).to be 4
    end
    job.build(Rmk::AlwaysBuildPolicy.new)
    job.result
  end

  it 'arguments are passed with implicit_dependencies' do
    job = Rmk::Job.new('job1', PLAN, [1, 2]) do |a, b, hidden|
      expect(a).to be 1
      expect(b).to be 2
      expect(hidden).to satisfy{ |h| h.is_a?(Hash) }
    end
    job.build(Rmk::AlwaysBuildPolicy.new)
    job.result
  end

  it 'jobs are passed as result' do
    job1 = Rmk::Job.new('job1', PLAN, []) do
      'hello'
    end

    job2 = Rmk::Job.new('job2', PLAN, [job1]) do |j|
      j
    end

    job2.build(Rmk::ModificationTimeBuildPolicy.new)
    expect(job2.result).to be 'hello'
  end

  it 'handle exceptions correct' do

    job = Rmk::Job.new('job1', PLAN, []) do
      raise StandardError, 'test'
    end
    # start build
    job.build(Rmk::ModificationTimeBuildPolicy.new)
    expect(job.exception).not_to be_nil
    expect { job.result }.to raise_error(StandardError)
  end

  it 'propagate exceptions' do

    job1 = Rmk::Job.new('job1', PLAN, []) do
      raise StandardError, 'test'
    end

    job2 = Rmk::Job.new('job2', PLAN, [job1]) do |j|
    end

    expect { job2.build(Rmk::ModificationTimeBuildPolicy.new) }.to raise_error(StandardError)
    expect(job1.exception).not_to be_nil
    expect(job2.exception).not_to be_nil
    expect { job1.result }.to raise_error(StandardError)
    expect { job2.result }.to raise_error(StandardError)
  end
end
