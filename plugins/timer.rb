# frozen_string_literal: true

module Timer
  class TimerJob
    def initialize(interval, base)
      @interval = interval
      @base = base
      @mtime = Time.now
      trigger
    end

    def mtime
      @mtime
    end

    def result
      @mtime
    end

    def trigger
      now = Time.now
      next_trigger = @base + (((now - @base) / @interval).to_i + 1) * @interval
      EventMachine.add_timer(next_trigger - now) do
        @mtime = Time.now
        Trigger.trigger
        trigger
      end
    end

    def to_s
      "Timer(#{@interval},#{@base})"
    end
  end

  def timer(interval, base: nil)
    base ||= Time.at(0)
    [TimerJob.new(interval, base)]
  end
end
