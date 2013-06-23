module Zookeeper
module ClientMethods
  extend Forwardable
  include Constants
  include ACLs
  include Logger

  # @req_registry is set up in the platform-specific base classes
  def_delegators :@req_registry, :setup_call
  private :setup_call

  def reopen(timeout=10, watcher=nil, opts = {})
    warn "WARN: ZookeeperBase#reopen watcher argument is now ignored" if watcher
    super
  end

  def initialize(host, timeout=10, watcher=nil, opts = {})
    super
  end

  def add_auth(options = {})
    assert_open
    assert_keys(options, 
                :supported => [:scheme, :cert],
                :required  => [:scheme, :cert])

    req_id = setup_call(:add_auth, options)
    rc = super(req_id, options[:scheme], options[:cert])

    { :req_id => req_id, :rc => rc }
  end

  def get(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :watcher, :watcher_context, :callback, :callback_context],
                :required   => [:path])

    req_id = setup_call(:get, options)
    rc, value, stat = super(req_id, options[:path], options[:callback], options[:watcher])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:data => value, :stat => Stat.new(stat))
  end

  def set(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :data, :version, :callback, :callback_context],
                :required   => [:path])

    assert_valid_data_size!(options[:data])
    options[:version] ||= -1

    req_id = setup_call(:set, options)
    rc, stat = super(req_id, options[:path], options[:data], options[:callback], options[:version])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:stat => Stat.new(stat))
  end

  def get_children(options = {})
    assert_open
    assert_keys(options,
                :supported => [:path, :callback, :callback_context, :watcher, :watcher_context],
                :required  => [:path])

    req_id = setup_call(:get_children, options)
    rc, children, stat = super(req_id, options[:path], options[:callback], options[:watcher])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:children => children, :stat => Stat.new(stat))
  end

  def stat(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :callback, :callback_context, :watcher, :watcher_context],
                :required   => [:path])

    req_id = setup_call(:stat, options)
    rc, stat = exists(req_id, options[:path], options[:callback], options[:watcher])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:stat => Stat.new(stat))
  end

  def create(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :data, :acl, :ephemeral, :sequence, :callback, :callback_context],
                :required   => [:path])

    assert_valid_data_size!(options[:data])

    flags = 0
    flags |= ZOO_EPHEMERAL if options[:ephemeral]
    flags |= ZOO_SEQUENCE if options[:sequence]

    options[:acl] ||= ZOO_OPEN_ACL_UNSAFE

    req_id = setup_call(:create, options)
    rc, newpath = super(req_id, options[:path], options[:data], options[:callback], options[:acl], flags)

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:path => newpath)
  end

  def delete(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :version, :callback, :callback_context],
                :required   => [:path])

    options[:version] ||= -1

    req_id = setup_call(:delete, options)
    rc = super(req_id, options[:path], options[:version], options[:callback])

    { :req_id => req_id, :rc => rc }
  end

  # this method is *only* asynchronous
  #
  # @note There is a discrepancy between the zkc and java versions. zkc takes
  #   a string_callback_t, java takes a VoidCallback. You should most likely use
  #   the Zookeeper::Callbacks::VoidCallback and not rely on the string value.
  #
  def sync(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :callback, :callback_context],
                :required   => [:path, :callback])

    req_id = setup_call(:sync, options)

    rc = super(req_id, options[:path]) # we don't pass options[:callback] here as this method is *always* async

    { :req_id => req_id, :rc => rc }
  end

  def set_acl(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :acl, :version, :callback, :callback_context],
                :required   => [:path, :acl])
    options[:version] ||= -1

    req_id = setup_call(:set_acl, options)
    rc = super(req_id, options[:path], options[:acl], options[:callback], options[:version])

    { :req_id => req_id, :rc => rc }
  end

  def get_acl(options = {})
    assert_open
    assert_keys(options,
                :supported  => [:path, :callback, :callback_context],
                :required   => [:path])

    req_id = setup_call(:get_acl, options)
    rc, acls, stat = super(req_id, options[:path], options[:callback])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:acl => acls, :stat => Stat.new(stat))
  end

  # close this client and any underlying connections
  def close
    super
  end

  def state
    super
  end

  def connected?
    super
  end

  def connecting?
    super
  end

  def associating?
    super
  end
  
  # There are some operations that are dangerous in the context of the event
  # dispatch thread (because they would block further event delivery). This
  # method allows clients to know if they're currently executing in the context of an
  # event.
  #
  # @returns [true,false] true if the current thread is the event dispatch thread
  def event_dispatch_thread?
    super
  end

  # DEPRECATED: use the class-level method instead
  def set_debug_level(val)
    super
  end

  # has the underlying connection been closed?
  def closed?
    super
  end

  # is the event delivery system running?
  def running?
    super
  end

  # return the session id of the current connection as an Fixnum
  def session_id
    super
  end

  # Return the passwd portion of this connection's credentials as a String
  def session_passwd
    super
  end

  # stop all underlying threads in preparation for a fork()
  def pause_before_fork_in_parent
    super
  end

  # re-start all underlying threads after performing a fork()
  def resume_after_fork_in_parent
    super
  end

protected
  # used during shutdown, awaken the event delivery thread if it's blocked
  # waiting for the next event
  def wake_event_loop!
    super
  end
  
  # starts the event delivery subsystem going. after calling this method, running? will be true
  def setup_dispatch_thread!
    super
  end

  # TODO: describe what this does
  def get_default_global_watcher
    super
  end

  def assert_valid_data_size!(data)
    return if data.nil?

    data = data.to_s
    if data.length >= 1048576 # one megabyte 
      raise Zookeeper::Exceptions::DataTooLargeException, "data must be smaller than 1 MiB, your data starts with: #{data[0..32].inspect}"
    end
    nil
  end

private
  def assert_keys(args, opts={})
    supported = opts[:supported] || []
    required  = opts[:required]  || []

    unless (args.keys - supported).empty?
      raise Zookeeper::Exceptions::BadArguments,
            "Supported arguments are: #{supported.inspect}, but arguments #{args.keys.inspect} were supplied instead"
    end

    unless (required - args.keys).empty?
      raise Zookeeper::Exceptions::BadArguments,
            "Required arguments are: #{required.inspect}, but only the arguments #{args.keys.inspect} were supplied."
    end
  end
  
  # must be supplied by parent class impl.
  def assert_open
    super
  end
end # ClientMethods
end # Zookeeper
