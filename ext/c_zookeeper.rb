require File.expand_path('../zookeeper_c', __FILE__)

# TODO: see if we can get the destructor to handle thread/event queue teardown
#       when we're garbage collected
class CZookeeper
  include ZookeeperCommon
  include ZookeeperConstants
  include ZookeeperExceptions

  DEFAULT_SESSION_TIMEOUT_MSEC = 10000

  class GotNilEventException < StandardError; end

  def initialize(host, event_queue, opts={})
    @host = host
    @event_queue = event_queue
    
    # used by the C layer. CZookeeper sets this to true when the init method
    # has completed. once this is set to true, it stays true.
    #
    # you should grab the @start_stop_mutex before messing with this flag
    @_running = nil

    # This is set to true after destroy_zkrb_instance has been called and all
    # CZookeeper state has been cleaned up
    @_closed = false  # also used by the C layer

    # set by the ruby side to indicate we are in shutdown mode used by method_get_next_event
    @_shutting_down = false

    # the actual C data is stashed in this ivar. never *ever* touch this
    @_data = nil

    @_session_timeout_msec = DEFAULT_SESSION_TIMEOUT_MSEC

    @start_stop_mutex = Monitor.new
    
    # used to signal that we're running
    @running_cond = @start_stop_mutex.new_cond
    
    @event_thread = nil

    setup_event_thread!

    zkrb_init(@host)

    logger.debug { "init returned!" }
  end

  def closed?
    @start_stop_mutex.synchronize { !!@_closed }
  end

  def running?
    @start_stop_mutex.synchronize { !!@_running }
  end

  def shutting_down?
    @start_stop_mutex.synchronize { !!@_shutting_down }
  end

  def connected?
    state == ZOO_CONNECTED_STATE
  end

  def connecting?
    state == ZOO_CONNECTING_STATE
  end

  def associating?
    state == ZOO_ASSOCIATING_STATE
  end

  def close
    return if closed?

    shut_down!
    stop_event_thread!

    @start_stop_mutex.synchronize do
      if !@_closed and @_data
        close_handle
      end
    end

    close_selectable_io!
    nil
  end

  def state
    return ZOO_CLOSED_STATE if closed?
    zkrb_state
  end

  # this implementation is gross, but i don't really see another way of doing it
  # without more grossness
  #
  # returns true if we're connected, false if we're not
  #
  # if timeout is nil, we never time out, and wait forever for CONNECTED state
  #
  def wait_until_connected(timeout=10)
    return false unless wait_until_running(timeout)

    time_to_stop = timeout ? (Time.now + timeout) : nil

    until connected? or (time_to_stop and Time.now > time_to_stop)
      Thread.pass
    end

    connected?
  end

  private
    # will wait until the client has entered the running? state
    # or until timeout seconds have passed.
    #
    # returns true if we're running, false if we timed out
    def wait_until_running(timeout=5)
      @start_stop_mutex.synchronize do
        return true if @_running
        @running_cond.wait(timeout)
        !!@_running
      end
    end

    def setup_event_thread!
      @event_thread ||= Thread.new do
        Thread.current.abort_on_exception = true   # remove this once this is confirmed to work

        logger.debug { "event_thread waiting until running: #{@_running}" }

        @start_stop_mutex.synchronize do
          @running_cond.wait_until { @_running }

          if @_shutting_down
            logger.error { "event thread saw @_shutting_down, bailing without entering loop" }
            return
          end
        end

        logger.debug { "event_thread running: #{@_running}" }

        while true
          begin
            _iterate_event_delivery
          rescue GotNilEventException
            logger.debug { "#{self.class}##{__method__}: event delivery thread is exiting" }
            break
          end
        end

        # TODO: should we try iterating events after this point? to see if any are left?
      end
    end

    def _iterate_event_delivery
      get_next_event(true).tap do |hash|
        raise GotNilEventException if hash.nil?
        @event_queue.push(hash)
      end
    end

    # use this method to set the @_shutting_down flag to true
    def shut_down!
      logger.debug { "#{self.class}##{__method__}" }

      @start_stop_mutex.synchronize do
        @_shutting_down = true
      end
    end

    # this method is part of the reopen/close code, and is responsible for
    # shutting down the dispatch thread. 
    #
    # @dispatch will be nil when this method exits
    #
    def stop_event_thread!
      logger.debug { "#{self.class}##{__method__}" }

      if @event_thread
        unless @_closed
          wake_event_loop! # this is a C method
        end
        @event_thread.join 
        @event_thread = nil
      end
    end

    def close_selectable_io!
      logger.debug { "#{self.class}##{__method__}" }
      
      # this is set up in the C init method, but it's easier to 
      # do the teardown here, as this is our half of a pipe. The
      # write half is controlled by the C code and will be closed properly 
      # when close_handle is called
      begin
        @selectable_io.close if @selectable_io
      rescue IOError
      end
    end

    def logger
      Zookeeper.logger
    end

    # called by underlying C code to signal we're running
    def zkc_set_running_and_notify!
      logger.debug { "#{self.class}##{__method__}" }

      @start_stop_mutex.synchronize do
        @_running = true
        @running_cond.broadcast
      end
    end
end

