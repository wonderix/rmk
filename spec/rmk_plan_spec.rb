# frozen_string_literal: true

require_relative '../lib/rmk.rb'


class MyPlan < Rmk::Plan
  job_method :method1, :method2
  def method1(a)
    raise "Invalid parameter" unless a == 1
  end
  def method2(a, b)
    raise "Invalid parameter" unless a == 1
    raise "Invalid parameter" unless b == 2
  end
end


describe Rmk::Plan do
  around(:each) do |example|
    EventMachine.run do
      Fiber.new do
        example.run
        EventMachine.stop
      end.resume
    end
  end

  it 'job_methods works as expected' do
    plan = MyPlan.new(nil,"","")
    job1 = plan.method1(1)
    job1.build(Rmk::AlwaysBuildPolicy.new())
    job1.result
    job2 = plan.method2(1, 2)
    job2.build(Rmk::AlwaysBuildPolicy.new())
    job2.result
  end

end
