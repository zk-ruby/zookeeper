module Zookeeper
  # @private
  module Continuation
    # sigh, slightly different than the userland callbacks, the continuation
    # provides sync call semantics around an async api
    class Base
      include Constants
      include Logger

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
      }
      
      # maps the method name to the async return hash keys it should use to
      # deliver the results
      METH_TO_ASYNC_RESULT_KEYS = {
        :get          => [:rc, :data, :stat],
        :set          => [:rc, :stat],
        :exists       => [:rc, :stat],
        :create       => [:rc, :string],
        :delete       => [:rc],
        :get_acl      => [:rc, :acl, :stat]
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
      def process
        @mutex.lock
        begin
          @cond.wait(@mutex) until @rval

          return @rval
        ensure
          @mutex.unlock
        end
      end

      # receive the response from the server, set @rval, notify caller
      def call(hash)
        @rval = hash.values_at(METH_TO_ASYNC_RESULT_KEYS.fetch(meth))
        deliver!
      end

      # this method is called by the event thread to submit the request
      # passed the CZookeeper instance, makes the async call and deals with the results
      #
      # BTW: in case you were wondering this is a completely stupid
      # implementation, but it's more important to get *something* working and
      # passing specs, then refactor to make everything sane
      # 
      def submit(czk)
        rc, *_ = czk.__send__(@meth, *async_args)
        
        if user_callback or (rc != ZOK)       # if this is an async call, or we failed to submit it
          @rval = [rc]                        # create the repsonse
          deliver!                            # wake the caller and we're out
        end
      end

      def req_id
        @args.first
      end

      protected
        def unpack_async_result(hash)
          case meth
          when :get
            hash.values_at(:rc, :data, :stat)
          when :set, :exists
            hash.values_at(:rc, :stat)
          when :get_children
            hash.values_at(:rc, :strings, :stat)
          when :create
            hash.values_at(
          end
        end

        # an args array with the only difference being that if there's a user
        # callback provided, we don't handle delivering the end result
        def async_args
          ary = @args.dup
          ary[callback_arg_idx] ||= self
          ary
        end

        def user_callback
          @args.at(callback_arg_idx)
        end

        def callback_arg_idx
          CALLBACK_ARG_IDX.fetch(meth) { raise ArgumentError, "unknown method #{meth.inspect}" } 
        end

        def deliver!
          @mutex.lock
          begin
            @cond.signal
          ensure
            @mutex.unlock
          end
        end
    end # Base
  end
end

