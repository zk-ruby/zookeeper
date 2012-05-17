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

    def initialize
      @array = []

      @mutex    = Mutex.new
      @cond     = ConditionVariable.new
      @closed   = false
      @graceful = false
    end

    def clear
      @mutex.lock
      begin
        @array.clear
      ensure
        @mutex.unlock rescue nil
      end
    end

    def push(obj)
      @mutex.lock
      begin
#         raise ShutdownException if (@closed or @graceful)
        @array << obj
        @cond.signal
      ensure
        @mutex.unlock rescue nil
      end
    end

    def pop(non_blocking=false)
      rval = nil

      @mutex.lock
      begin

        begin
          raise ShutdownException if @closed  # this may get us in trouble

          rval = @array.shift

          unless rval
            raise ThreadError if non_blocking     # sigh, ruby's stupid behavior
            raise ShutdownException if @graceful  # we've processed all the remaining mesages

            @cond.wait(@mutex) until (@closed or @graceful or (@array.length > 0))
          end
        end until rval

        return rval

      ensure
        @mutex.unlock rescue nil
      end
    end

    # close the queue and causes ShutdownException to be raised on waiting threads
    def graceful_close!
      @mutex.lock
      begin
        return if @graceful or @closed
        logger.debug { "#{self.class}##{__method__} gracefully closing" }
        @graceful = true
        @cond.broadcast
      ensure
        @mutex.unlock rescue nil
      end
      nil
    end

    def open
      @mutex.lock
      begin
        @closed = @graceful = false
        @cond.broadcast
      ensure
        @mutex.unlock rescue nil
      end
    end

    def close
      @mutex.lock
      begin
        return if @closed
        @closed = true
        @cond.broadcast
      ensure
        @mutex.unlock rescue nil
      end
    end

    def closed?
      @mutex.synchronize { !!@closed }
    end
  end
end
end
