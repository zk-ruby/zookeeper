module Zookeeper
module Common
  # Ceci n'est pas une pipe
  class QueueWithPipe
    extend Forwardable
    include Logger

    # raised when close has been called, and pop() is performed
    # 
    class ShutdownException < StandardError; end

    # @private
    KILL_TOKEN = Object.new unless defined?(KILL_TOKEN)

    # @private
    COND_WAIT_TIMEOUT = 5

    def initialize
      @array = []

      @mutex    = Monitor.new
      @cond     = @mutex.new_cond
      @closed   = false
      @graceful = false
    end

    def clear
      @mutex.synchronize do
        @array.clear
      end
    end

    def push(obj)
      @mutex.synchronize do
        @array << obj
        @cond.signal
      end
    end

    def pop(non_blocking=false)
      rval = nil

      @mutex.synchronize do

        begin
          raise ShutdownException if @closed  # this may get us in trouble

          rval = @array.shift

          unless rval
            raise ThreadError if non_blocking     # sigh, ruby's stupid behavior
            raise ShutdownException if @graceful  # we've processed all the remaining mesages

            @cond.wait(COND_WAIT_TIMEOUT) until (@closed or @graceful or (@array.length > 0))
          end
        end until rval

        return rval

      end
    end

    # close the queue and causes ShutdownException to be raised on waiting threads
    def graceful_close!
      @mutex.synchronize do
        return if @graceful or @closed
        logger.debug { "#{self.class}##{__method__} gracefully closing" }
        @graceful = true
        @cond.broadcast
      end
      nil
    end

    def open
      @mutex.synchronize do
        @closed = @graceful = false
        @cond.broadcast
      end
    end

    def close
      @mutex.synchronize do
        return if @closed
        @closed = true
        @cond.broadcast
      end
    end

    def closed?
      @mutex.synchronize { !!@closed }
    end
  end
end
end
