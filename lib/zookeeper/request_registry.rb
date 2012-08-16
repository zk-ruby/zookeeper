module Zookeeper
  class RequestRegistry
    def initialize
      @mutex = Monitor.new

      @current_req_id   = 0
      @watcher_reqs     = {}
      @completion_reqs  = {}
    end

    def setup_call(meth_name, opts)
      req_id = nil
      @mutex.synchronize {
        req_id = @current_req_id
        @current_req_id += 1
        setup_completion(req_id, meth_name, opts) if opts[:callback]
        setup_watcher(req_id, opts)               if opts[:watcher]
      }
      req_id
    end

    def get_completion(req_id, opts={})
      @mutex.synchronize do
        if opts[:keep] 
          @completion_reqs[req_id]
        else
          @completion_reqs.delete(req_id)
        end
      end
    end

    # Return the watcher hash associated with the req_id. If the req_id
    # is the ZKRB_GLOBAL_CB_REQ, then does not clear the req from the internal
    # store, otherwise the req_id is removed.
    #
    def get_watcher(req_id, opts={})
      @mutex.synchronize do
        if (Constants::ZKRB_GLOBAL_CB_REQ == req_id) or opts[:keep]
          @watcher_reqs[req_id]
        else
          @watcher_reqs.delete(req_id)
        end
      end
    end

    private
      def setup_watcher(req_id, call_opts)
        @mutex.synchronize do
          @watcher_reqs[req_id] = { 
            :watcher => call_opts[:watcher],
            :context => call_opts[:watcher_context] 
          }
        end
      end

      # as a hack, to provide consistency between the java implementation and the C
      # implementation when dealing w/ chrooted connections, we override this in
      # ext/zookeeper_base.rb to wrap the callback in a chroot-path-stripping block.
      #
      # we don't use meth_name here, but we need it in the C implementation
      #
      def setup_completion(req_id, meth_name, call_opts)
        @mutex.synchronize do
          @completion_reqs[req_id] = { 
            :callback => call_opts[:callback],
            :context  => call_opts[:callback_context]
          }
        end
      end
  end
end

