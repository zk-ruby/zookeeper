require_relative '../lib/zookeeper/logger'
require_relative '../lib/zookeeper/common'
require_relative '../lib/zookeeper/constants'
require_relative '../lib/zookeeper/exceptions' # zookeeper_c depends on exceptions defined in here
require_relative 'zookeeper_c'

# require File.expand_path('../zookeeper_c', __FILE__)

module Zookeeper
# NOTE: this class extending (opening) the class defined in zkrb.c
class CZookeeper
  include Forked
  include Constants
  include Exceptions
  include Logger

  DEFAULT_SESSION_TIMEOUT_MSEC = 10000

  class GotNilEventException < StandardError; end

  attr_accessor :original_pid

  # assume we're at debug level
  def self.get_debug_level
    @debug_level ||= ZOO_LOG_LEVEL_INFO
  end

  def self.set_debug_level(value)
    @debug_level = value
    set_zkrb_debug_level(value)
  end

  # wrap these calls in our sync->async special sauce
  %w[get set exists create delete get_acl set_acl get_children].each do |sym|
    class_eval(<<-EOS, __FILE__, __LINE__+1)
      def #{sym}(*args)
        submit_and_block(:#{sym}, *args)
      end
    EOS
  end

  def initialize(host, event_queue, opts={})
    @host = host
    @event_queue = event_queue

    # keep track of the pid that created us
    update_pid!
    
    # used by the C layer. CZookeeper sets this to true when the init method
    # has completed. once this is set to true, it stays true.
    #
    # you should grab the @mutex before messing with this flag
    @_running = nil

    # This is set to true after destroy_zkrb_instance has been called and all
    # CZookeeper state has been cleaned up
    @_closed = false  # also used by the C layer

    # set by the ruby side to indicate we are in shutdown mode used by method_get_next_event
    @_shutting_down = false

    # the actual C data is stashed in this ivar. never *ever* touch this
    @_data = nil

    @_session_timeout_msec = DEFAULT_SESSION_TIMEOUT_MSEC

    @mutex = Monitor.new
    
    # used to signal that we're running
    @running_cond = @mutex.new_cond

    # used to signal we've received the connected event
    @connected_cond = @mutex.new_cond

    @pipe_read, @pipe_write = IO.pipe
    
    @event_thread = nil

    # hash of in-flight Continuation instances
    @reg = Continuation::Registry.new

    log_level = ENV['ZKC_DEBUG'] ? ZOO_LOG_LEVEL_DEBUG : ZOO_LOG_LEVEL_ERROR

    zkrb_init(@host)#, :zkc_log_level => log_level)

    start_event_thread

    logger.debug { "init returned!" }
  end

  def closed?
    @mutex.synchronize { !!@_closed }
  end

  def running?
    @mutex.synchronize { !!@_running }
  end

  def shutting_down?
    @mutex.synchronize { !!@_shutting_down }
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

    fn_close = proc do
      if !@_closed and @_data
        logger.debug { "CALLING CLOSE HANDLE!!" }
        close_handle
      end
    end

    if forked?
      fn_close.call
    else
      stop_event_thread
      @mutex.synchronize(&fn_close)
    end

    [@pipe_read, @pipe_write].each { |io| io.close unless io.closed? }

    nil
  end
  
  # call this to stop the event loop, you can resume with the
  # resume method
  #
  # requests may still be added during this time, but they will not be
  # processed until you call resume
  def pause_before_fork_in_parent
    logger.debug { "#{self.class}##{__method__}" }
    @mutex.synchronize { stop_event_thread }
  end

  # call this if 'pause' was previously called to start the event loop again
  def resume_after_fork_in_parent
    logger.debug { "#{self.class}##{__method__}" }

    @mutex.synchronize do 
      @_shutting_down = nil
      start_event_thread
    end
  end

  def state
    return ZOO_CLOSED_STATE if closed?
    submit_and_block(:state)
  end

  # this implementation is gross, but i don't really see another way of doing it
  # without more grossness
  #
  # returns true if we're connected, false if we're not
  #
  # if timeout is nil, we never time out, and wait forever for CONNECTED state
  #
  def wait_until_connected(timeout=10)
    # this begin/ensure/end style is recommended by tarceri
    # no need to create a context for every mutex grab

    wait_until_running(timeout)

    Thread.pass until connected? or is_unrecoverable
    connected?
  end

  private
    # submits a job for processing 
    # blocks the caller until result has returned
    def submit_and_block(meth, *args)
      cnt = Continuation.new(meth, *args)
      @reg.lock 
      begin
        if meth == :state
          @reg.state_check << cnt
        else
          @reg.pending << cnt
        end
      ensure
        @reg.unlock rescue nil
      end
      wake_event_loop!
      cnt.value
    end
    
    # this method is part of the reopen/close code, and is responsible for
    # shutting down the dispatch thread. 
    #
    # @event_thread will be nil when this method exits
    #
    def stop_event_thread
      if @event_thread
        logger.debug { "#{self.class}##{__method__}" }
        shut_down!
        wake_event_loop!
        @event_thread.join 
        @event_thread = nil
      end
    end

    # starts the event thread running if not already started
    # returns false if already running
    def start_event_thread
      return false if @event_thread
      @event_thread = Thread.new(&method(:event_thread_body))
    end

    # will wait until the client has entered the running? state
    # or until timeout seconds have passed.
    #
    # returns true if we're running, false if we timed out
    def wait_until_running(timeout=5) 
      @mutex.lock
      begin
        return true if @_running
        @running_cond.wait(timeout)
        !!@_running
      ensure
        @mutex.unlock rescue nil
      end
    end

    def event_thread_body
      Thread.current.abort_on_exception = true
      logger.debug { "#{self.class}##{__method__} starting event thread" }

      event_thread_await_running

      # this is the main loop
      until (@_shutting_down or @_closed or is_unrecoverable)
        submit_pending_calls    if @reg.anything_to_do?
        zkrb_iterate_event_loop 
        iterate_event_delivery
      end

      # ok, if we're exiting the event loop, and we still have a valid connection
      # and there's still completions we're waiting to hear about, then we
      # should pump the handle before leaving this loop
      if @_shutting_down and not (@_closed or is_unrecoverable or @reg.in_flight.empty?)
        logger.debug { "we're in shutting down state, ensuring we have no in-flight completions" }

        until @reg.in_flight.empty?
          zkrb_iterate_event_loop
          iterate_event_delivery
        end

        logger.debug { "finished completions" }
      end

    rescue ShuttingDownException
      logger.error { "event thread saw @_shutting_down, bailing without entering loop" }
    ensure
      logger.debug { "#{self.class}##{__method__} exiting" }
    end

    def submit_pending_calls
      calls = @reg.next_batch()

      return if calls.empty?

      while cntn = calls.shift
        cntn.submit(self)                     # this delivers state check results (and does other stuff)
        if req_id = cntn.req_id               # state checks will not have a req_id
          @reg.in_flight[req_id] = cntn       # in_flight is only ever touched by us
        end
      end
    end

    def wake_event_loop!
      @pipe_write && @pipe_write.write('1')
    end

    def iterate_event_delivery
      while hash = zkrb_get_next_event_st()
        logger.debug { "#{self.class}##{__method__} got #{hash.inspect} " }

        # notify when we get this event so we know we're connected
        if hash.values_at(:req_id, :type, :state) == CONNECTED_EVENT_VALUES[1..2]
          notify_connected!
        end

        cntn = @reg.in_flight.delete(hash[:req_id])

        if cntn and not cntn.user_callback?     # this is one of "our" continuations 
          cntn.call(hash)                       # so we handle delivering it
          next                                  # and skip handing it to the dispatcher
        end

        # otherwise, the event was a session event (ZKRB_GLOBAL_CB_REQ)
        # or a user-provided callback
        @event_queue.push(hash)
      end
    end

    def event_thread_await_running
      logger.debug { "event_thread waiting until running: #{@_running}" }

      @mutex.lock
      begin
        @running_cond.wait_until { @_running or @_shutting_down }
        logger.debug { "event_thread running: #{@_running}" }

        raise ShuttingDownException if @_shutting_down
      ensure
        @mutex.unlock rescue nil
      end
    end

    # use this method to set the @_shutting_down flag to true
    def shut_down!
      logger.debug { "#{self.class}##{__method__}" }

      @mutex.synchronize { @_shutting_down = true }
    end

    # called by underlying C code to signal we're running
    def zkc_set_running_and_notify!
      logger.debug { "#{self.class}##{__method__}" }

      @mutex.lock
      begin
        @_running = true
        @running_cond.broadcast
      ensure
        @mutex.unlock rescue nil
      end
    end

    def notify_connected!
      @mutex.lock
      begin
        @connected_cond.broadcast
      ensure
        @mutex.unlock rescue nil
      end
    end
end
end
