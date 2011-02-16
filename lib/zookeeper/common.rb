module ZookeeperCommon
  # sigh, i guess define this here?
  ZKRB_GLOBAL_CB_REQ   = -1

  def self.included(mod)
    mod.extend(ZookeeperCommon::ClassMethods)
  end

  module ClassMethods
    def logger
      @logger ||= Logger.new('/dev/null') # UNIX: YOU MUST USE IT!
    end

    def logger=(logger)
      @logger = logger
    end
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


  def dispatch_next_callback
    hash = get_next_event
    return nil unless hash
    
    logger.debug {  "dispatch_next_callback got event: #{hash.inspect}" }

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

  # supplied by parent class impl.
  def logger
    self.class.logger
  end
end

