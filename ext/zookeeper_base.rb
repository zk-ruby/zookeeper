require 'forwardable'

Zookeeper.require_root 'ext/c_zookeeper'

# The low-level wrapper-specific methods for the C lib
# subclassed by the top-level Zookeeper class
module Zookeeper
class ZookeeperBase
  extend Forwardable
  include Forked
  include Common       # XXX: clean this up, no need to include *everything*
  include Callbacks
  include Constants
  include Exceptions
  include ACLs
  include Logger

  attr_accessor :original_pid

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


  def_delegators :czk, :get_children, :exists, :delete, :get, :set,
    :set_acl, :get_acl, :client_id, :sync, :wait_until_connected

  def self.threadsafe_inquisitor(*syms)
    syms.each do |sym|
      class_eval(<<-EOM, __FILE__, __LINE__+1)
        def #{sym}
          c = @mutex.synchronize { @czk }
          false|(c && c.#{sym})
        end
      EOM
    end
  end

  threadsafe_inquisitor :connected?, :connecting?, :associating?, :running?

  attr_reader :event_queue
  
  # this method may be called in either the fork case, or from the constructor
  # to set up this state initially (so all of this is in one location). we rely
  # on the forked? method to determine which it is
  def reopen_after_fork!
    logger.debug { "#{self.class}##{__method__} fork detected!" } if forked?

    @mutex = Monitor.new
    @dispatch_shutdown_cond = @mutex.new_cond
    @event_queue = QueueWithPipe.new

    @dispatcher = nil if @dispatcher and not @dispatcher.alive?

    update_pid!  # from Forked
  end
  private :reopen_after_fork!


  def reopen(timeout = 10, watcher=nil)
    if watcher and (watcher != @default_watcher)
      raise "You cannot set the watcher to a different value this way anymore!"
    end

    reopen_after_fork! if forked?

    @mutex.synchronize do
      @czk.close if @czk
      @czk = CZookeeper.new(@host, @event_queue)

      # flushes all outstanding watcher reqs.
      @watcher_reqs.clear
      set_default_global_watcher
      
      @czk.wait_until_connected(timeout)
    end

    setup_dispatch_thread!
    state
  end

  def initialize(host, timeout = 10, watcher=nil)
    @watcher_reqs = {}
    @completion_reqs = {}

    @current_req_id = 0

    @dispatcher = @czk = nil

    update_pid!
    reopen_after_fork!
    
    # approximate the java behavior of raising java.lang.IllegalArgumentException if the host
    # argument ends with '/'
    raise ArgumentError, "Host argument #{host.inspect} may not end with /" if host.end_with?('/')

    @host = host.dup

    @default_watcher = (watcher or get_default_global_watcher)

    yield self if block_given?

    reopen(timeout)
  end

  # if either of these happen, the user will need to renegotiate a connection via reopen
  def assert_open
    @mutex.synchronize do
      raise Exceptions::NotConnected if !@czk or @czk.closed?
      if forked?
        raise InheritedConnectionError, <<-EOS.gsub(/(?:^|\n)\s*/, ' ').strip
          You tried to use a connection inherited from another process 
          (original pid: #{original_pid}, your pid: #{Process.pid})
          You need to call reopen() after forking
        EOS
      end
    end
  end

  # do not lock, do not mutex, just close the underlying handle this is
  # potentially dangerous and should only be called after a fork() to close
  # this instance
  def close!
    inst, @czk = @czk, nil
    inst && inst.close
  end

  # close the connection normally, stops the dispatch thread and closes the
  # underlying connection cleanly
  def close
    sd_thread = nil

    @mutex.synchronize do
      return unless @czk
      inst, @czk = @czk, nil
    
      sd_thread = Thread.new(inst) do |_inst|
        stop_dispatch_thread!
        _inst.close
      end
    end

    # if we're on the event dispatch thread for some stupid reason, then don't join
    unless event_dispatch_thread?
      # hard-coded 30 second delay, don't hang forever
      if sd_thread.join(30) != sd_thread 
        logger.error { "timed out waiting for shutdown thread to exit" }
      end
    end

    nil
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
    @mutex.synchronize do
      cid = client_id and cid.session_id
    end
  end

  def session_passwd
    @mutex.synchronize do
      cid = client_id and cid.passwd
    end
  end

  # we are closed if there is no @czk instance or @czk.closed?
  def closed?
    czk.closed?
  rescue Exceptions::NotConnected
    true
  end

  def pause_before_fork_in_parent
    @mutex.synchronize do
      logger.debug { "ZookeeperBase#pause_before_fork_in_parent" }

      # XXX: add anal-retentive state checking 
      raise "EXPLODERATE! @czk was nil!" unless @czk

      @czk.pause_before_fork_in_parent
      stop_dispatch_thread!
    end
  end

  def resume_after_fork_in_parent
    @mutex.synchronize do
      logger.debug { "ZookeeperBase#resume_after_fork_in_parent" }

      raise "EXPLODERATE! @czk was nil!" unless @czk

      event_queue.open
      setup_dispatch_thread!
      @czk.resume_after_fork_in_parent
    end
  end

protected
  # this is a hack: to provide consistency between the C and Java drivers when
  # using a chrooted connection, we wrap the callback in a block that will
  # strip the chroot path from the returned path (important in an async create
  # sequential call). This is the only place where we can hook *just* the C
  # version. The non-async manipulation is handled in ZookeeperBase#create.
  # 
  # TODO: need to move the continuation setup into here, so that it can get 
  #       added to the callback hash
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

    # pass this along to the Zookeeper::Common implementation
    super(req_id, meth_name, call_opts)
  end

  def czk
    rval = @mutex.synchronize { @czk }
    raise Exceptions::NotConnected unless rval
    rval
  end

  # if we're chrooted, this method will strip the chroot prefix from +path+
  def strip_chroot_from(path)
    return path unless (chrooted? and path and path.start_with?(chroot_path))
    path[chroot_path.length..-1]
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
end
