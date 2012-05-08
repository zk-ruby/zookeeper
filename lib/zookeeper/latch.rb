module Zookeeper
  # a cross-thread gate of sorts.
  class Latch
    def initialize(count = 1)
      @count = count
      @mutex = Monitor.new
      @cond = @mutex.new_cond
    end

    def release
      @mutex.synchronize {
        @count -= 1 if @count > 0
        @cond.broadcast if @count.zero?
      }
    end

    def await(timeout=nil)
      @mutex.synchronize do
        if timeout
          time_to_stop = Time.now + timeout

          while @count > 0
            @cond.wait(timeout)
            
            break if (Time.now > time_to_stop)
          end
        else
          @cond.wait_while { @count > 0 }
        end
      end
    end
  end
end

