require 'zookeeper'
require 'eventmachine'

module ZookeeperEM 
  class Client < Zookeeper
    # @private
    # the EM Connection instance we receive once we call EM.watch on our selectable_io
    attr_reader :em_connection

    def initialize(*a, &b)
      @on_close       = EM::DefaultDeferrable.new
      @on_attached    = EM::DefaultDeferrable.new
      @em_connection  = nil
      super(*a, &b)
    end

    # EM::DefaultDeferrable that will be called back when our em_connection has been detached
    # and we've completed the close operation
    def on_close(&block)
      @on_close.callback(&block) if block
      @on_close
    end

    # called after we've successfully registered our selectable_io to be
    # managed by the EM reactor
    def on_attached(&block)
      @on_attached.callback(&block) if block
      @on_attached
    end

    # returns a Deferrable that will be called when the Zookeeper C event loop
    # has been shut down 
    #
    # if a block is given, it will be registered as a callback when the
    # connection has been closed
    #
    def close(&block)
      logger.debug { "close called, closed? #{closed?} running? #{running?}" }

      unless running?
        logger.debug { "we are not running, so returning on_close deferred" }
        return on_close(&block)
      end

      @_running = false
      wake_event_loop! unless closed?

      @on_close.callback(&block) if block

      if @em_connection
        logger.debug { "we have an @em_connection, so detach" }
        @em_connection.detach
      else
        really_close
      end

      on_close
    end

    # make this public as the ZKConnection object needs to call it
    public :dispatch_next_callback

  protected
    def really_close
      unless closed?
        logger.debug { "calling close_handle in native driver" }
        close_handle

        logger.debug { "calling on_close.succeed" }
        on_close.succeed
      end
    end

    # instead of setting up a dispatch thread here, we instead attach
    # the #selectable_io to the event loop 
    def setup_dispatch_thread!
      EM.schedule do
        begin
          @em_connection = EM.watch(selectable_io, ZKConnection, self) { |cnx| cnx.notify_readable = true }
          @em_connection.on_detach.callback(&method(:really_close))
          @em_connection.on_detach.errback(&method(:really_close))
        rescue Exception => e
          $stderr.puts "caught exception from EM.watch(): #{e.inspect}"
        end
        on_attached.succeed
      end
    end
  end

  # this class is handed to EventMachine.watch to handle event dispatching
  # when the queue has a message waiting. There's a pipe shared between 
  # the event thread managed by the queue implementation in C. It's made
  # available to the ruby-space through the Zookeeper#selectable_io method.
  # When the pipe is readable, that means there's an event waiting. We call
  # dispatch_next_event and read a single byte off the pipe.
  #
  class ZKConnection < EM::Connection

    def initialize(zk_client)
      @zk_client = zk_client
      @on_detach = EM::DefaultDeferrable.new
      @on_detach.callback { logger.debug { "on_detach callback fired" } }
    end

    # called back when we've successfully detached from the EM reactor
    def on_detach(&blk)
      @on_detach.callback(&blk) if blk
      @on_detach
    end

    def receive_data(data)
      logger.debug { "receive_data called: #{data.inspect}" }
    end

    def detach
      super
      @on_detach.succeed
    end

    # we have an event waiting
    def notify_readable
      if @zk_client.running?
        logger.debug { "dispatching events while #{@zk_client.running?}" }
        EM.next_tick { notify_readable } if @zk_client.dispatch_next_callback(false)
      else
        logger.debug { "@zk_client was not running? we're detaching!" }
        detach
      end
    end

    private
      def logger
        Zookeeper.logger
      end
  end
end

