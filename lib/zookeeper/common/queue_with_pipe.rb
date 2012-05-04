module Zookeeper
module Common
  # Ceci n'est pas une pipe
  class QueueWithPipe
    extend Forwardable

    def_delegators :@queue, :clear
    
    # raised when close has been called, and pop() is performed
    # 
    class ShutdownException < StandardError; end

    # @private
    KILL_TOKEN = Object.new unless defined?(KILL_TOKEN)

    def initialize
      @queue = Queue.new

      @mutex = Mutex.new
      @closed = false
      @graceful = false
    end

    def push(obj)
      logger.debug { "#{self.class}##{__method__} obj: #{obj.inspect}, kill_token? #{obj == KILL_TOKEN}" }
      @queue.push(obj)
    end

    def pop(non_blocking=false)
      raise ShutdownException if closed?  # this may get us in trouble

      rv = @queue.pop(non_blocking)

      if rv == KILL_TOKEN
        close
        raise ShutdownException
      end

      rv
    end

    # close the queue and causes ShutdownException to be raised on waiting threads
    def graceful_close!
      @mutex.synchronize do
        return if @graceful or @closed
        logger.debug { "#{self.class}##{__method__} gracefully closing" }
        @graceful = true
        push(KILL_TOKEN)
      end
      nil
    end

    def close
      @mutex.synchronize do
        return if @closed
        @closed = true
      end
    end

    def closed?
      @mutex.synchronize { !!@closed }
    end

    private
      def clear_reads_on_pop?
        @clear_reads_on_pop
      end

      def logger
        Zookeeper.logger
      end
  end
end
end
