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
describe Rmk::Job, '#relative_path_from' do
  around(:each) do |example|
    example.run
    FileUtils.rm_rf(PLAN.build_dir)
  end

  it 'propagate exceptions' do
    plan = PlanMock.new

    job1 = Rmk::Job.new('job1', PLAN, []) do
      puts 'running'
      raise StandardError, 'test'
    end

    job2 = Rmk::Job.new('job2', PLAN, [job1]) do
    end

    expect { job2.build(Rmk::ModificationTimeBuildPolicy.new) }.to raise_error(StandardError)
    expect(job1.exception).not_to be_nil
    expect(job2.exception).not_to be_nil
    expect { job1.result }.to raise_error(StandardError)
    expect { job2.result }.to raise_error(StandardError)
  end
end
