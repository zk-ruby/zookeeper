# Ruby wrapper for the Zookeeper C API

require 'thread'
require 'zookeeper/common'
require 'zookeeper/constants'
require 'zookeeper/callbacks'
require 'zookeeper/exceptions'
require 'zookeeper/stat'
require 'zookeeper/acls'
require 'logger'

if defined?(::JRUBY_VERSION)
  $LOAD_PATH.unshift(File.expand_path('../java', File.dirname(__FILE__))).uniq!
else
  $LOAD_PATH.unshift(File.expand_path('../ext', File.dirname(__FILE__))).uniq!
  require 'zookeeper_c'
end

require 'zookeeper_base'

class Zookeeper < ZookeeperBase
  def reopen(timeout=10, watcher=nil)
    super
  end

  def initialize(host, timeout=10, watcher=nil)
    super
  end

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

private
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

  # TODO: Sanitize user mistakes by unregistering watchers from ops that
  # don't return ZOK (except wexists)?  Make users clean up after themselves for now.
  def unregister_watcher(req_id)
    @req_mutex.synchronize {
      @watcher_reqs.delete(req_id)
    }
  end
  
  # must be supplied by parent class impl.
  def assert_open
    super
  end

end

