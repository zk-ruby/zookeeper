module Zookeeper
  # @private
  module Continuation
    # sigh, slightly different than the userland callbacks, the continuation
    # provides sync call semantics around an async api
    class Continuation
      include Constants
      include Logger

      attr_accessor :meth, :args, :block, :rval

      def initialize(meth, req_id, *args, &block)
        @meth   = meth
        @req_id = req_id
        @args   = args
        @block  = block
        @mutex  = Monitor.new
        @cond   = @mutex.new_cond
        @rval   = []
      end

      def process

      end

      def call(hash)

      end

      # called by the event thread when the job has been submitted, with the 
      # return value. if the rv is not ZOK, then we wake the caller and deliver
      # the result (usually an error)
      def submission_response(rc, *args)
        logger.debug { "req_id: #{req_id}, meth: #{meth.inspect}, got submission response: rc: #{rc}, args: #{args.inspect}" } 

        if rc != ZOK
          @rval = [rc].concat(args)
          notify_caller!
        end
      end

      private
        def notify_caller!
        end
    end
  end
end

