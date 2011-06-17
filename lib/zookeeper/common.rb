module ZookeeperCommon
  # sigh, i guess define this here?
  ZKRB_GLOBAL_CB_REQ   = -1

  def get_next_event(blocking=true)
    return nil if closed? # protect against this happening in a callback after close
    super(blocking) 
  end

protected
  def setup_call(opts)
    req_id = nil
    @req_mutex.synchronize {
      req_id = @current_req_id
      @current_req_id += 1
      setup_completion(req_id, opts) if opts[:callback]
      setup_watcher(req_id, opts) if opts[:watcher]
    }
    req_id
  end
  
  def setup_watcher(req_id, call_opts)
    @watcher_reqs[req_id] = { :watcher => call_opts[:watcher],
                              :context => call_opts[:watcher_context] }
  end

  def setup_completion(req_id, call_opts)
    @completion_reqs[req_id] = { :callback => call_opts[:callback],
                                 :context => call_opts[:callback_context] }
  end
  
  def get_watcher(req_id)
    @req_mutex.synchronize {
      req_id != ZKRB_GLOBAL_CB_REQ ? @watcher_reqs.delete(req_id) : @watcher_reqs[req_id]
    }
  end
  
  def get_completion(req_id)
    @req_mutex.synchronize { @completion_reqs.delete(req_id) }
  end

  def dispatch_next_callback(blocking=true)
    hash = get_next_event(blocking)
#     Zookeeper.logger.debug { "get_next_event returned: #{hash.inspect}" }

    return nil unless hash
    
    is_completion = hash.has_key?(:rc)
    
    hash[:stat] = ZookeeperStat::Stat.new(hash[:stat]) if hash.has_key?(:stat)
    hash[:acl] = hash[:acl].map { |acl| ZookeeperACLs::ACL.new(acl) } if hash[:acl]
    
    callback_context = is_completion ? get_completion(hash[:req_id]) : get_watcher(hash[:req_id])

    # when connectivity with the server is lost, on reconnection it's possible
    # to receive duplicate responses. If we've already handled a response for a
    # given req_id, this value will be nil, and we just ignore it.
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

end

