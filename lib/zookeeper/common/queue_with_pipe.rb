module ZookeeperCommon
  # Ceci n'est pas une pipe
  class QueueWithPipe
    attr_writer :clear_reads_on_pop
    
    # raised when close has been called, and pop() is performed
    # 
    class ShutdownException < StandardError; end

    # @private
    KILL_TOKEN = Object.new unless defined?(KILL_TOKEN)

    def initialize
      r, w = IO.pipe
      @pipe = { :read => r, :write => w }
      @queue = Queue.new

      # with the EventMachine client, we want to let EM handle clearing the
      # event pipe, so we set this to false
      @clear_reads_on_pop = true

      @mutex = Mutex.new
      @closed = false
    end

    def push(obj)
      rv = @queue.push(obj)
      begin
        if pw = @pipe[:write] 
          pw.write('0')
        end
      rescue IOError
        # this may happen when shutting down (going to get rid of this stupid IO anyway..)
      end
      rv
    end

    def pop(non_blocking=false)
      raise ShutdownException if closed?  # this may get us in trouble

      rv = @queue.pop(non_blocking)

      if rv == KILL_TOKEN
        close
        raise ShutdownException
      end

      # if non_blocking is true and an exception is raised, this won't get called
      # (by design)
      @pipe[:read].read(1)

      rv
    end

    # close the queue and causes ShutdownException to be raised on waiting threads
    def graceful_close!
      clear
      push(KILL_TOKEN)
      nil
    end

    def clear
      @queue.clear
    end

    def close
      @mutex.synchronize do
        return if @closed
        @pipe.values.each { |io| io.close unless io.closed? }
        @pipe.clear
        @closed = true
      end
    end

    def selectable_io
      @pipe[:read]
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
