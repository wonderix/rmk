module Timer

  class TimerJob
    def initialize(interval,base)
      @interval = interval
      @base = base
      mtime()
    end

    def mtime()
      offset = (( Time.now() - @base )/  @interval).to_i * @interval
      @time  =  @base + offset
    end

    def result
      @time
    end

    def to_s()
      "Timer(#{@interval},#{@base})"
    end
  end

  def timer(interval, base: nil)
    base ||= Time.at(0)
    return [ TimerJob.new(interval, base) ]
  end

end
