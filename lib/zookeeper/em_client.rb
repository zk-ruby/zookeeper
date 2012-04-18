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
      logger.debug { "ZookeeperEM::Client obj_id %x: init" % [object_id] }
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
      on_close(&block)

      logger.debug { "#{self.class.name}: close called, closed? #{closed?} running? #{running?}" }

      if @_running
        stop_running!

        if @em_connection
          EM.next_tick do
            @em_connection.detach do
              logger.debug { "#{self.class.name}: connection unbound, continuing with shutdown" }
              finish_closing
            end
          end
        else
          logger.debug { "#{self.class.name}: em_connection was never set up, finish closing" }
          finish_closing
        end
      else
        logger.debug { "#{self.class.name}: we are not running, so returning on_close deferred" }
      end

      on_close
    end

    # make this public as the ZKConnection object needs to call it
    public :dispatch_next_callback

  protected
    # instead of setting up a dispatch thread here, we instead attach
    # the #selectable_io to the event loop 
    def setup_dispatch_thread!
      EM.schedule do
        if running? and not closed?
          begin
            logger.debug { "adding EM.watch(#{selectable_io.inspect})" }
            @em_connection = EM.watch(selectable_io, ZKConnection, self) { |cnx| cnx.notify_readable = true }
          rescue Exception => e
            $stderr.puts "caught exception from EM.watch(): #{e.inspect}"
          end
        end
      end
    end

    def finish_closing
      unless @_closed
        @start_stop_mutex.synchronize do
          logger.debug { "closing handle" }
          close_handle
        end

        unless selectable_io.closed?
          logger.debug { "calling close on selectable_io: #{selectable_io.inspect}" }
          selectable_io.close
        end
      end

      on_close.succeed
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
    end

    def post_init
      logger.debug { "post_init called" }
      @attached = true

      @on_unbind = EM::DefaultDeferrable.new.tap do |d|
        d.callback do
          logger.debug { "on_unbind deferred fired" }
        end
      end

      # probably because of the way post_init works, unless we fire this
      # callback in next_tick @em_connection in the client may not be set
      # (which on_attached callbacks may be relying on)
      EM.next_tick do 
        logger.debug { "firing on_attached callback" }
        @zk_client.on_attached.succeed
      end
    end
    
    # EM::DefaultDeferrable that will be called back when our em_connection has been detached
    # and we've completed the close operation
    def on_unbind(&block)
      @on_unbind.callback(&block) if block
      @on_unbind
    end

    def attached?
      @attached
    end

    def unbind
      on_unbind.succeed
    end

    def detach(&blk)
      on_unbind(&blk)
      return unless @attached
      @attached = false
      rval = super()
      logger.debug { "#{self.class.name}: detached, rval: #{rval.inspect}" }
    end

    # we have an event waiting
    def notify_readable
      if @zk_client.running?

        read_io_nb if @zk_client.dispatch_next_callback(false)

      elsif attached?
        logger.debug { "#{self.class.name}: @zk_client was not running? and attached? #{attached?}, detaching!" }
        detach
      end
    end

    private
      def read_io_nb(size=1)
        @io.read_nonblock(1)
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN, IOError
      end
      
      def logger
        Zookeeper.logger
      end
  end
end

