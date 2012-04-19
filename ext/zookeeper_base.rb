require File.expand_path('../c_zookeeper', __FILE__)
require 'forwardable'

# The low-level wrapper-specific methods for the C lib
# subclassed by the top-level Zookeeper class
class ZookeeperBase
  extend Forwardable
  include ZookeeperCommon
  include ZookeeperCallbacks
  include ZookeeperConstants
  include ZookeeperExceptions
  include ZookeeperACLs
  include ZookeeperStat

  # @private
  class ClientShutdownException < StandardError; end

  # @private
  KILL_TOKEN = Object.new unless defined?(KILL_TOKEN)

  ZKRB_GLOBAL_CB_REQ   = -1

  # debug levels
  ZOO_LOG_LEVEL_ERROR  = 1
  ZOO_LOG_LEVEL_WARN   = 2
  ZOO_LOG_LEVEL_INFO   = 3
  ZOO_LOG_LEVEL_DEBUG  = 4

  def_delegators :czk, 
    :get_children, :exists, :delete, :get, :set, :set_acl, :get_acl, :client_id, :sync, :selectable_io

  # some state methods need to be more paranoid about locking to ensure the correct
  # state is returned
  # 
  def self.threadsafe_inquisitor(*syms)
    syms.each do |sym|
      class_eval(<<-EOM, __FILE__, __LINE__+1)
        def #{sym}
          @mutex.synchronize { @czk and @czk.#{sym} }
        end
      EOM
    end
  end

  threadsafe_inquisitor :connected?, :connecting?, :associating?, :running?
 
  def reopen(timeout = 10, watcher=nil)
    warn "WARN: ZookeeperBase#reopen watcher argument is now ignored" if watcher

    if watcher and (watcher != @default_watcher)
      raise "You cannot set the watcher to a different value this way anymore!"
    end
    
    @mutex.synchronize do
      # flushes all outstanding watcher reqs.
      @watcher_reqs.clear
      set_default_global_watcher

      @czk = CZookeeper.new(@host, @event_queue)
      @czk.wait_until_connected(timeout)
    end

    setup_dispatch_thread!
    state
  end

  def initialize(host, timeout = 10, watcher=nil)
    @watcher_reqs = {}
    @completion_reqs = {}
    @mutex = Monitor.new
    @current_req_id = 0
    @event_queue = QueueWithPipe.new
    @czk = nil
    
    # approximate the java behavior of raising java.lang.IllegalArgumentException if the host
    # argument ends with '/'
    raise ArgumentError, "Host argument #{host.inspect} may not end with /" if host.end_with?('/')

    @host = host

    @default_watcher = (watcher or get_default_global_watcher)

    yield self if block_given?

    reopen(timeout)
  end

  # synchronized accessor to the @czk instance
  # @private
  def czk
    @mutex.synchronize { @czk }
  end
  
  # if either of these happen, the user will need to renegotiate a connection via reopen
  def assert_open
    raise ZookeeperException::SessionExpired if state == ZOO_EXPIRED_SESSION_STATE
    raise ZookeeperException::NotConnected   unless connected?
  end

  def close
    stop_dispatch_thread!

    @mutex.synchronize do
      @czk.close
    end
  end

  # the C lib doesn't strip the chroot path off of returned path values, which
  # is pretty damn annoying. this is used to clean things up.
  def create(*args)
    # since we don't care about the inputs, just glob args
    rc, new_path = czk.create(*args)
    [rc, strip_chroot_from(new_path)]
  end

  def set_debug_level(int)
    warn "DEPRECATION WARNING: #{self.class.name}#set_debug_level, it has moved to the class level and will be removed in a future release"
    self.class.set_debug_level(int)
  end

  # set the watcher object/proc that will receive all global events (such as session/state events)
  def set_default_global_watcher
    warn "DEPRECATION WARNING: #{self.class}#set_default_global_watcher ignores block" if block_given?

    @mutex.synchronize do
#       @default_watcher = block # save this here for reopen() to use
      @watcher_reqs[ZKRB_GLOBAL_CB_REQ] = { :watcher => @default_watcher, :watcher_context => nil }
    end
  end

  def state
    return ZOO_CLOSED_STATE if closed?
    czk.state
  end

  def session_id
    cid = client_id and cid.session_id
  end

  def session_passwd
    cid = client_id and cid.passwd
  end

  # we are closed if there is no @czk instance or @czk.closed?
  def closed?
    @mutex.synchronize { !@czk or @czk.closed? } 
  end
 
protected
  def close_selectable_io!
    logger.debug { "#{self.class}##{__method__}" }
    
    # this is set up in the C init method, but it's easier to 
    # do the teardown here, as this is our half of a pipe. The
    # write half is controlled by the C code and will be closed properly 
    # when close_handle is called
    begin
      @selectable_io.close if @selectable_io
    rescue IOError
    end
  end

  # this is a hack: to provide consistency between the C and Java drivers when
  # using a chrooted connection, we wrap the callback in a block that will
  # strip the chroot path from the returned path (important in an async create
  # sequential call). This is the only place where we can hook *just* the C
  # version. The non-async manipulation is handled in ZookeeperBase#create.
  # 
  def setup_completion(req_id, meth_name, call_opts)
    if (meth_name == :create) and cb = call_opts[:callback]
      call_opts[:callback] = lambda do |hash|
        # in this case the string will be the absolute zookeeper path (i.e.
        # with the chroot still prepended to the path). Here's where we strip it off
        hash[:string] = strip_chroot_from(hash[:string])

        # call the original callback
        cb.call(hash)
      end
    end

    # pass this along to the ZookeeperCommon implementation
    super(req_id, meth_name, call_opts)
  end

  # if we're chrooted, this method will strip the chroot prefix from +path+
  def strip_chroot_from(path)
    return path unless (chrooted? and path and path.start_with?(chroot_path))
    path[chroot_path.length..-1]
  end

  
  # this method is part of the reopen/close code, and is responsible for
  # shutting down the dispatch thread. 
  #
  # @dispatch will be nil when this method exits
  #
  def stop_dispatch_thread!
    logger.debug { "#{self.class}##{__method__}" }

    if @dispatcher
      @event_queue.graceful_close!
      @dispatcher.join 
      @dispatcher = nil
    end
  end

  def get_default_global_watcher
    Proc.new { |args|
      logger.debug { "Ruby ZK Global CB called type=#{event_by_value(args[:type])} state=#{state_by_value(args[:state])}" }
      true
    }
  end

  def chrooted?
    !chroot_path.empty?
  end

  def chroot_path
    if @chroot_path.nil?
      @chroot_path = 
        if idx = @host.index('/')
          @host.slice(idx, @host.length)
        else
          ''
        end
    end

    @chroot_path
  end
end

