module Zookeeper
  # @private
  # sigh, slightly different than the userland callbacks, the continuation
  # provides sync call semantics around an async api
  class Continuation
    include Constants
    include Logger

    # for keeping track of which continuations are pending, and which ones have
    # been submitted and are awaiting a repsonse
    # 
    # `state_check` are high-priority checks that query the connection about
    # its current state, they always run before other continuations
    #
    class Registry < Struct.new(:pending, :in_flight)
      extend Forwardable

      def_delegators :@mutex, :lock, :unlock

      def initialize
        super([], {})
        @mutex = Mutex.new
      end

      def synchronized
        @mutex.lock
        begin
          yield self
        ensure
          @mutex.unlock rescue nil
        end
      end

      # does not lock the mutex, returns true if there are pending jobs
      def anything_to_do?
        !pending.empty?
      end

      # returns the pending continuations, resetting the list
      # this method is synchronized
      def next_batch()
        @mutex.lock
        begin
          pending.slice!(0,pending.length)
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
    }

    attr_accessor :meth, :block, :rval

    def initialize(meth, *args)
      @meth   = meth
      @args   = args
      @mutex  = Mutex.new
      @cond   = ConditionVariable.new
      @rval   = nil
      
      # set to true when an event occurs that would cause the caller to
      # otherwise block forever
      @interrupt = false
    end

    # the caller calls this method and receives the response from the async loop
    def value
      @mutex.lock
      begin
        @cond.wait(@mutex) until @rval

        case @rval.length
        when 1
          return @rval.first
        else
          return @rval
        end
      ensure
        @mutex.unlock
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
    def submit(czk)
      rc, *_ = czk.__send__(:"zkrb_#{@meth}", *async_args)
      
      # if this is an state call, async call, or we failed to submit it
      if (@meth == :state) or user_callback? or (rc != ZOK)
        @rval = [rc]           # create the repsonse
        deliver!               # wake the caller and we're out
      end
    end

    def req_id
      @args.first
    end

    def state_call?
      @meth == :state
    end

    protected

      # an args array with the only difference being that if there's a user
      # callback provided, we don't handle delivering the end result
      def async_args
        return [] if @meth == :state    # special-case :P
        ary = @args.dup

        logger.debug { "async_args, meth: #{meth} ary: #{ary.inspect}, #{callback_arg_idx}" }

        # this is not already an async call
        # so we replace the req_id with the ZKRB_ASYNC_CONTN_ID so the 
        # event thread knows to dispatch it itself
        ary[callback_arg_idx] ||= self

        ary
      end

      def callback_arg_idx
        CALLBACK_ARG_IDX.fetch(meth) { raise ArgumentError, "unknown method #{meth.inspect}" } 
      end

      def deliver!
        @mutex.lock
        begin
          @cond.signal
        ensure
          @mutex.unlock rescue nil
        end
      end
  end # Base
end

