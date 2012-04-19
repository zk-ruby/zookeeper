module ZookeeperCommon
  # Ceci n'est pas une pipe
  class QueueWithPipe
    attr_writer :clear_reads_on_pop

    def initialize
      r, w = IO.pipe
      @pipe = { :read => r, :write => w }
      @queue = Queue.new

      # with the EventMachine client, we want to let EM handle clearing the
      # event pipe, so we set this to false
      @clear_reads_on_pop = true
    end

    def push(obj)
      rv = @queue.push(obj)
      @pipe[:write].write('0')
      logger.debug { "pushed #{obj.inspect} onto queue and wrote to pipe" }
      rv
    end

    def pop(non_blocking=false)
      rv = @queue.pop(non_blocking)

      # if non_blocking is true and an exception is raised, this won't get called
      # (by design)
      @pipe[:read].read(1) if clear_reads_on_pop?

      rv
    end

    def close
      @pipe.values.each { |io| io.close unless io.closed? }
    end

    def selectable_io
      @pipe[:read]
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
