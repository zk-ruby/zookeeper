# Ruby wrapper for the Zookeeper C API

require 'zookeeper_c'
require 'thread'
require 'zookeeper/callbacks'
require 'zookeeper/constants'
require 'zookeeper/exceptions'
require 'zookeeper/stat'
require 'zookeeper/acls'

class Zookeeper < CZookeeper
  include ZookeeperCallbacks
  include ZookeeperConstants
  include ZookeeperExceptions
  include ZookeeperACLs
  include ZookeeperStat

  ZKRB_GLOBAL_CB_REQ   = -1

  # debug levels
  ZOO_LOG_LEVEL_ERROR  = 1
  ZOO_LOG_LEVEL_WARN   = 2
  ZOO_LOG_LEVEL_INFO   = 3
  ZOO_LOG_LEVEL_DEBUG  = 4

  def reopen(timeout = 10)
    init(@host)
    if timeout > 0
      time_to_stop = Time.now + timeout
      until state == Zookeeper::ZOO_CONNECTED_STATE
        break if Time.now > time_to_stop
        sleep 0.1
      end
    end
    # flushes all outstanding watcher reqs.
    @watcher_reqs = { ZKRB_GLOBAL_CB_REQ => { :watcher => get_default_global_watcher } }
    state
  end

  def initialize(host, timeout = 10)
    @watcher_reqs = {}
    @completion_reqs = {}
    @req_mutex = Mutex.new
    @current_req_id = 1
    @host = host
    return nil if reopen(timeout) != Zookeeper::ZOO_CONNECTED_STATE
    setup_dispatch_thread!
  end

public
  def get(options = {})
    assert_open
    assert_supported_keys(options, [:path, :watcher, :watcher_context, :callback, :callback_context])
    assert_required_keys(options, [:path])

    req_id = setup_call(options)
    rc, value, stat = super(req_id, options[:path], options[:callback], options[:watcher])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:data => value, :stat => Stat.new(stat))
  end

  def set(options = {})
    assert_open
    assert_supported_keys(options, [:path, :data, :version, :callback, :callback_context])
    assert_required_keys(options, [:path])
    options[:version] ||= -1

    req_id = setup_call(options)
    rc, stat = super(req_id, options[:path], options[:data], options[:callback], options[:version])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:stat => Stat.new(stat))
  end

  def get_children(options = {})
    assert_open
    assert_supported_keys(options, [:path, :callback, :callback_context, :watcher, :watcher_context])
    assert_required_keys(options, [:path])

    req_id = setup_call(options)
    rc, children, stat = super(req_id, options[:path], options[:callback], options[:watcher])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:children => children, :stat => Stat.new(stat))
  end

  def stat(options = {})
    assert_open
    assert_supported_keys(options, [:path, :callback, :callback_context, :watcher, :watcher_context])
    assert_required_keys(options, [:path])

    req_id = setup_call(options)
    rc, stat = exists(req_id, options[:path], options[:callback], options[:watcher])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:stat => Stat.new(stat))
  end

  def create(options = {})
    assert_open
    assert_supported_keys(options, [:path, :data, :acl, :ephemeral, :sequence, :callback, :callback_context])
    assert_required_keys(options, [:path])

    flags = 0
    flags |= ZOO_EPHEMERAL if options[:ephemeral]
    flags |= ZOO_SEQUENCE if options[:sequence]

    options[:acl] ||= ZOO_OPEN_ACL_UNSAFE

    req_id = setup_call(options)
    rc, newpath = super(req_id, options[:path], options[:data], options[:callback], options[:acl], flags)

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:path => newpath)
  end

  def delete(options = {})
    assert_open
    assert_supported_keys(options, [:path, :version, :callback, :callback_context])
    assert_required_keys(options, [:path])
    options[:version] ||= -1

    req_id = setup_call(options)
    rc = super(req_id, options[:path], options[:version], options[:callback])

    { :req_id => req_id, :rc => rc }
  end

  def set_acl(options = {})
    assert_open
    assert_supported_keys(options, [:path, :acl, :version, :callback, :callback_context])
    assert_required_keys(options, [:path, :acl])
    options[:version] ||= -1

    req_id = setup_call(options)
    rc = super(req_id, options[:path], options[:acl], options[:callback], options[:version])

    { :req_id => req_id, :rc => rc }
  end

  def get_acl(options = {})
    assert_open
    assert_supported_keys(options, [:path, :callback, :callback_context])
    assert_required_keys(options, [:path])

    req_id = setup_call(options)
    rc, acls, stat = super(req_id, options[:path], options[:callback])

    rv = { :req_id => req_id, :rc => rc }
    options[:callback] ? rv : rv.merge(:acl => acls, :stat => Stat.new(stat))
  end

private
  def setup_dispatch_thread!
    @dispatcher = Thread.new {
      while true do
        dispatch_next_callback
      end
    }
  end

  def dispatch_next_callback
    hash = get_next_event

    is_completion = hash.has_key?(:rc)

    hash[:stat] = Stat.new(hash[:stat]) if hash.has_key?(:stat)
    hash[:acl] = hash[:acl].map { |acl| ACL.new(acl) } if hash[:acl]

    callback_context = is_completion ? get_completion(hash[:req_id]) : get_watcher(hash[:req_id])
    callback = is_completion ? callback_context[:callback] : callback_context[:watcher]
    hash[:context] = callback_context[:context]

    # TODO: Eventually enforce derivation from Zookeeper::Callback
    if callback.respond_to?(:call)
      callback.call(hash)
    else
      # puts "dispatch_next_callback found non-callback => #{callback.inspect}"
    end
  end

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

public
  # TODO: Sanitize user mistakes by unregistering watchers from ops that
  # don't return ZOK (except wexists)?  Make users clean up after themselves for now.
  def unregister_watcher(req_id)
    @req_mutex.synchronize {
      @watcher_reqs.delete(req_id)
    }
  end

private
  # TODO: Make all global puts configurable
  def get_default_global_watcher
    Proc.new { |args|
      # puts "Ruby ZK Global CB called type=#{event_by_value(args[:type])} state=#{state_by_value(args[:state])}"
      true
    }
  end

  # if either of these happen, the user will need to renegotiate a connection via reopen
  def assert_open
    if state == ZOO_EXPIRED_SESSION_STATE
      raise ZookeeperException::SessionExpired
    elsif state != Zookeeper::ZOO_CONNECTED_STATE
      raise ZookeeperException::ConnectionClosed
    end
  end

  def assert_supported_keys(args, supported)
    unless (args.keys - supported).empty?
      raise ZookeeperException::BadArguments,
            "Supported arguments are: #{supported.inspect}, but arguments #{args.keys.inspect} were supplied instead"
    end
  end

  def assert_required_keys(args, required)
    unless (required - args.keys).empty?
      raise ZookeeperException::BadArguments,
            "Required arguments are: #{required.inspect}, but only the arguments #{args.keys.inspect} were supplied."
    end
  end
end

