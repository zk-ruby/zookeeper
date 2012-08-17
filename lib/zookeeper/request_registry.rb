module Zookeeper
  class RequestRegistry
    include Constants
    include Logger

    # @param [Hash] opts
    # @option opts [String] :chroot_path (nil) if given, will be used to
    #   correct a discrepancy between the C and Java clients when using a
    #   chrooted connection. If given, the chroot path will be stripped from
    #   the string returned by a `create`. It should be an absolute path.
    #
    def initialize(watcher, opts={})
      @mutex = Monitor.new

      @default_watcher  = watcher

      @current_req_id   = 0
      @watcher_reqs     = {}
      @completion_reqs  = {}

      @chroot_path = opts[:chroot_path]
    end

    def default_watcher
      @mutex.synchronize { @default_watcher }
    end

    def default_watcher=(blk)
      @mutex.synchronize { @default_watcher = blk }
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

    def get_context_for(hash)
      return nil unless hash

      is_session_event  = (hash[:type] == ZOO_SESSION_EVENT)

      req_id  = hash.fetch(:req_id)

      if hash.has_key?(:rc)
        get_completion(req_id, :keep => is_session_event)
      else
        get_watcher(req_id, :keep => is_session_event)
      end
    end

    def clear_watchers!
      @mutex.synchronize { @watcher_reqs.clear }
    end
    
    # if we're chrooted, this method will strip the chroot prefix from +path+
    def strip_chroot_from(path)
      return path unless (chrooted? and path and path.start_with?(@chroot_path))
      path[@chroot_path.length..-1]
    end

    private
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
          if Constants::ZKRB_GLOBAL_CB_REQ == req_id
            { :watcher => @default_watcher, :watcher_context => nil }
          elsif opts[:keep]
            @watcher_reqs[req_id]
          else
            @watcher_reqs.delete(req_id)
          end
        end
      end


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
            :callback => maybe_wrap_callback(meth_name, call_opts[:callback]),
            :context  => call_opts[:callback_context]
          }
        end
      end

      # this is a hack: to provide consistency between the C and Java drivers when
      # using a chrooted connection, we wrap the callback in a block that will
      # strip the chroot path from the returned path (important in an async create
      # sequential call). This is the only place where we can hook *just* the C
      # version. The non-async manipulation is handled in ZookeeperBase#create.
      # 
      # TODO: need to move the continuation setup into here, so that it can get 
      #       added to the callback hash
      #
      def maybe_wrap_callback(meth_name, cb)
        return cb unless cb and chrooted? and (meth_name == :create)

        lambda do |hash|
          # in this case the string will be the absolute zookeeper path (i.e.
          # with the chroot still prepended to the path). Here's where we strip it off
          hash[:string] = strip_chroot_from(hash[:string])

          # call the original callback
          cb.call(hash)
        end
      end
      
      def chrooted?
        @chroot_path && !@chroot_path.empty?
      end

      def default_watcher_proc
        Proc.new { |args|
          logger.debug { "Ruby ZK Global CB called type=#{event_by_value(args[:type])} state=#{state_by_value(args[:state])}" }
          true
        }
      end
  end
end

