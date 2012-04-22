require 'zookeeper/exceptions'

module ZookeeperCommon
  # sigh, i guess define this here?
  ZKRB_GLOBAL_CB_REQ   = -1

  def event_dispatch_thread?
    @dispatcher && (@dispatcher == Thread.current)
  end

protected
  def get_next_event(blocking=true)
    @event_queue.pop(!blocking).tap do |event|
      logger.debug { "#{self.class}##{__method__} delivering event #{event.inspect}" }
    end
  rescue ThreadError
    nil
  end

  def setup_call(meth_name, opts)
    req_id = nil
    @mutex.synchronize {
      req_id = @current_req_id
      @current_req_id += 1
      setup_completion(req_id, meth_name, opts) if opts[:callback]
      setup_watcher(req_id, opts) if opts[:watcher]
    }
    req_id
  end
 
  def setup_watcher(req_id, call_opts)
    @watcher_reqs[req_id] = { :watcher => call_opts[:watcher],
                              :context => call_opts[:watcher_context] }
  end

  # as a hack, to provide consistency between the java implementation and the C
  # implementation when dealing w/ chrooted connections, we override this in
  # ext/zookeeper_base.rb to wrap the callback in a chroot-path-stripping block.
  #
  # we don't use meth_name here, but we need it in the C implementation
  #
  def setup_completion(req_id, meth_name, call_opts)
    @completion_reqs[req_id] = { :callback => call_opts[:callback],
                                 :context => call_opts[:callback_context] }
  end
  
  def get_watcher(req_id)
    @mutex.synchronize {
      (req_id == ZKRB_GLOBAL_CB_REQ) ? @watcher_reqs[req_id] : @watcher_reqs.delete(req_id)
    }
  end
  
  def get_completion(req_id)
    @mutex.synchronize { @completion_reqs.delete(req_id) }
  end

  def setup_dispatch_thread!
    logger.debug {  "starting dispatch thread" }
    @dispatcher ||= Thread.new do
      while true
        begin
          dispatch_next_callback(get_next_event(true))
        rescue QueueWithPipe::ShutdownException
          logger.info { "dispatch thread exiting, got shutdown exception" }
          break
        rescue Exception => e
          $stderr.puts ["#{e.class}: #{e.message}", e.backtrace.map { |n| "\t#{n}" }.join("\n")].join("\n")
        end
      end
      signal_dispatch_thread_exit!
    end
  end
  
  # this method is part of the reopen/close code, and is responsible for
  # shutting down the dispatch thread. 
  #
  # @dispatcher will be nil when this method exits
  #
  def stop_dispatch_thread!
    logger.debug { "#{self.class}##{__method__}" }

    if @dispatcher
      @mutex.synchronize do
        event_queue.graceful_close!

        # we now release the mutex so that dispatch_next_callback can grab it
        # to do what it needs to do while delivering events
        @dispatch_shutdown_cond.wait

        @dispatcher.join
        @dispatcher = nil
      end
    end
  end

  def signal_dispatch_thread_exit!
    @mutex.synchronize do
      logger.debug { "dispatch thread exiting!" }
      @dispatch_shutdown_cond.broadcast
    end
  end

  def dispatch_next_callback(hash)
    return nil unless hash

    Zookeeper.logger.debug { "get_next_event returned: #{prettify_event(hash).inspect}" }
    
    is_completion = hash.has_key?(:rc)
    
    hash[:stat] = ZookeeperStat::Stat.new(hash[:stat]) if hash.has_key?(:stat)
    hash[:acl] = hash[:acl].map { |acl| ZookeeperACLs::ACL.new(acl) } if hash[:acl]
    
    callback_context = is_completion ? get_completion(hash[:req_id]) : get_watcher(hash[:req_id])

    # When connectivity to the server has been lost (as indicated by SESSION_EVENT)
    # we want to rerun the callback at a later time when we eventually do have
    # a valid response.
    if hash[:type] == ZookeeperConstants::ZOO_SESSION_EVENT
      is_completion ? setup_completion(hash[:req_id], callback_context) : setup_watcher(hash[:req_id], callback_context)
    end
    if callback_context
      callback = is_completion ? callback_context[:callback] : callback_context[:watcher]

      hash[:context] = callback_context[:context]

      # TODO: Eventually enforce derivation from Zookeeper::Callback
      if callback.respond_to?(:call)
        callback.call(hash)
      else
        # puts "dispatch_next_callback found non-callback => #{callback.inspect}"
      end
    else
      logger.warn { "Duplicate event received (no handler for req_id #{hash[:req_id]}, event: #{hash.inspect}" }
    end
    true
  end

  def assert_supported_keys(args, supported)
    unless (args.keys - supported).empty?
      raise ZookeeperExceptions::ZookeeperException::BadArguments,  # this heirarchy is kind of retarded
            "Supported arguments are: #{supported.inspect}, but arguments #{args.keys.inspect} were supplied instead"
    end
  end

  def assert_required_keys(args, required)
    unless (required - args.keys).empty?
      raise ZookeeperExceptions::ZookeeperException::BadArguments,
            "Required arguments are: #{required.inspect}, but only the arguments #{args.keys.inspect} were supplied."
    end
  end

private
  def prettify_event(hash)
    hash.dup.tap do |h|
      # pretty up the event display
      h[:type]    = ZookeeperConstants::EVENT_TYPE_NAMES.fetch(h[:type]) if h[:type]
      h[:state]   = ZookeeperConstants::STATE_NAMES.fetch(h[:state]) if h[:state]
      h[:req_id]  = :global_session if h[:req_id] == -1
    end
  end
end

require 'zookeeper/common/queue_with_pipe'
