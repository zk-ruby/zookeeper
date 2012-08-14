module Zookeeper
  # @private
  # sigh, slightly different than the userland callbacks, the continuation
  # provides sync call semantics around an async api
  class Continuation
    include Constants
    include Logger

    OPERATION_TIMEOUT = 30 # seconds

    # for keeping track of which continuations are pending, and which ones have
    # been submitted and are awaiting a repsonse
    # 
    # `state_check` are high-priority checks that query the connection about
    # its current state, they always run before other continuations
    #
    class Registry < Struct.new(:pending, :state_check, :in_flight)
      extend Forwardable

      def_delegators :@mutex, :lock, :unlock

      def initialize
        super([], [], {})
        @mutex = Mutex.new
      end

      def synchronize
        @mutex.lock
        begin
          yield self
        ensure
          @mutex.unlock rescue nil
        end
      end

      # does not lock the mutex, returns true if there are pending jobs
      def anything_to_do?
        (pending.length + state_check.length) > 0
      end

      # returns the pending continuations, resetting the list
      # this method is synchronized
      def next_batch()
        @mutex.lock
        begin
          state_check.slice!(0, state_check.length) + pending.slice!(0,pending.length)
        ensure
          @mutex.unlock rescue nil
        end
      end
    end # Registry

    # *sigh* what is the index in the *args array of the 'callback' param
    CALLBACK_ARG_IDX = {
      :get => 2,
      :set => 3,
      :exists => 2,
      :create => 3,
      :delete => 3,
      :get_acl => 2,
      :set_acl => 3,
      :get_children => 2,
      :state => 0,
      :add_auth => 2
    }

    # maps the method name to the async return hash keys it should use to
    # deliver the results
    METH_TO_ASYNC_RESULT_KEYS = {
      :get          => [:rc, :data, :stat],
      :set          => [:rc, :stat],
      :exists       => [:rc, :stat],
      :create       => [:rc, :string],
      :delete       => [:rc],
      :get_acl      => [:rc, :acl, :stat],
      :set_acl      => [:rc],
      :get_children => [:rc, :strings, :stat],
      :add_auth     => [:rc]
    }

    attr_accessor :meth, :block, :rval

    attr_reader :args

    def initialize(meth, *args)
      @meth   = meth
      @args   = args.freeze
      @mutex  = Monitor.new
      @cond   = @mutex.new_cond
      @rval   = nil

      # make this error reporting more robust if necessary, right now, just set to state
      @error  = nil
    end

    # the caller calls this method and receives the response from the async loop
    # this method has a hard-coded 30 second timeout as a safety feature. No
    # call should take more than 20s (as the session timeout is set to 20s)
    # so if any call takes longer than that, something has gone horribly wrong.
    #
    # @raise [ContinuationTimeoutError] if a response is not received within 30s
    #
    def value
      time_to_stop = Time.now + OPERATION_TIMEOUT
      now = nil

      @mutex.synchronize do
        while true
          now = Time.now
          break if @rval or @error or (now > time_to_stop)

          deadline = time_to_stop.to_f - now.to_f
          @cond.wait(deadline)
        end

        if (now > time_to_stop) and !@rval and !@error
          raise Exceptions::ContinuationTimeoutError, "response for meth: #{meth.inspect}, args: #{@args.inspect}, not received within #{OPERATION_TIMEOUT} seconds"
        end

        case @error
        when nil
          # ok, nothing to see here, carry on
        when :shutdown
          raise Exceptions::NotConnected, "the connection is shutting down"
        when ZOO_EXPIRED_SESSION_STATE
          raise Exceptions::SessionExpired, "connection has expired"
        else
          raise Exceptions::NotConnected, "connection state is #{STATE_NAMES[@error]}"
        end

        case @rval.length
        when 1
          return @rval.first
        else
          return @rval
        end
      end
    end

    # receive the response from the server, set @rval, notify caller
    def call(hash)
      logger.debug { "continuation req_id #{req_id}, got hash: #{hash.inspect}" }
      @rval = hash.values_at(*METH_TO_ASYNC_RESULT_KEYS.fetch(meth))
      logger.debug { "delivering result #{@rval.inspect}" }
      deliver!
    end

    def user_callback?
      !!@args.at(callback_arg_idx)
    end

    # this method is called by the event thread to submit the request
    # passed the CZookeeper instance, makes the async call and deals with the results
    #
    # BTW: in case you were wondering this is a completely stupid
    # implementation, but it's more important to get *something* working and
    # passing specs, then refactor to make everything sane
    # 
    #
    def submit(czk)
      state = czk.zkrb_state    # check the state of the connection

      if @meth == :state        # if the method is a state call
        @rval = [state]         # we're done, no error
        return deliver!

      elsif state != ZOO_CONNECTED_STATE  # otherwise, we must be connected
        @error = state                    # so set the error
        return deliver!                   # and we're out
      end

      rc, *_ = czk.__send__(:"zkrb_#{@meth}", *async_args)
      
      if user_callback? or (rc != ZOK)  # async call, or we failed to submit it
        @rval = [rc]                    # create the repsonse
        deliver!                        # wake the caller and we're out
      end
    end

    def req_id
      @args.first
    end

    def state_call?
      @meth == :state
    end

    # interrupt the sleeping thread with a NotConnected error
    def shutdown!
      @mutex.synchronize do
        return if @rval or @error
        @error = :shutdown
        @cond.broadcast
      end
    end

    protected

      # an args array with the only difference being that if there's a user
      # callback provided, we don't handle delivering the end result
      def async_args
        return [] if @meth == :state    # special-case :P
        ary = @args.dup

        logger.debug { "async_args, meth: #{meth} ary: #{ary.inspect}, #{callback_arg_idx}" }

        ary[callback_arg_idx] ||= self

        ary
      end

      def callback_arg_idx
        CALLBACK_ARG_IDX.fetch(meth) { raise ArgumentError, "unknown method #{meth.inspect}" } 
      end

      def deliver!
        @mutex.synchronize do
          @cond.signal
        end
      end
  end # Base
end

