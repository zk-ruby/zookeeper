# The low-level wrapper-specific methods for the C lib
# subclassed by the top-level Zookeeper class
class ZookeeperBase < CZookeeper
  include ZookeeperCommon
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

 
  def reopen(timeout = 10, watcher=nil)
    watcher ||= @default_watcher

    @req_mutex.synchronize do
      # flushes all outstanding watcher reqs.
      @watcher_req = {}
      set_default_global_watcher(&watcher)
    end

    @start_stop_mutex.synchronize do
#       $stderr.puts "%s: calling init, self.obj_id: %x" % [self.class, object_id]
      init(@host)

      # XXX: replace this with a callback
      if timeout > 0
        time_to_stop = Time.now + timeout
        until state == Zookeeper::ZOO_CONNECTED_STATE
          break if Time.now > time_to_stop
          sleep 0.1
        end
      end
    end

    state
  end

  def initialize(host, timeout = 10, watcher=nil)
    @watcher_reqs = {}
    @completion_reqs = {}
    @req_mutex = Monitor.new
    @current_req_id = 1
    
    # approximate the java behavior of raising java.lang.IllegalArgumentException if the host
    # argument ends with '/'
    raise ArgumentError, "Host argument #{host.inspect} may not end with /" if host.end_with?('/')

    @host = host

    @start_stop_mutex = Monitor.new

    watcher ||= get_default_global_watcher

    @_running = nil   # used by the C layer
    @_closed = false  # also used by the C layer

    yield self if block_given?

    reopen(timeout, watcher)
    return nil unless connected?
    setup_dispatch_thread!
  end
  
  # if either of these happen, the user will need to renegotiate a connection via reopen
  def assert_open
    raise ZookeeperException::SessionExpired if state == ZOO_EXPIRED_SESSION_STATE
    raise ZookeeperException::NotConnected   unless connected?
  end

  def connected?
    state == ZOO_CONNECTED_STATE
  end

  def connecting?
    state == ZOO_CONNECTING_STATE
  end

  def associating?
    state == ZOO_ASSOCIATING_STATE
  end

  def close
    @start_stop_mutex.synchronize do
      @_running = false if @_running
    end

    if @dispatcher
      unless @_closed
        wake_event_loop! 
      end
      @dispatcher.join 
    end

    @start_stop_mutex.synchronize do
      unless @_closed
        close_handle
      end
    end
        
    # this is set up in the C init method, but it's easier to 
    # do the teardown here
    begin
      @selectable_io.close if @selectable_io
    rescue IOError
    end
  end

  def set_debug_level(int)
    warn "DEPRECATION WARNING: #{self.class.name}#set_debug_level, it has moved to the class level and will be removed in a future release"
    self.class.set_debug_level(int)
  end

  # set the watcher object/proc that will receive all global events (such as session/state events)
  def set_default_global_watcher(&block)
    @req_mutex.synchronize do
      @default_watcher = block # save this here for reopen() to use
      @watcher_reqs[ZKRB_GLOBAL_CB_REQ] = { :watcher => @default_watcher, :watcher_context => nil }
    end
  end

  def closed?
    @start_stop_mutex.synchronize { false|@_closed }
  end

  def running?
    @start_stop_mutex.synchronize { false|@_running }
  end

  def state
    return ZOO_CLOSED_STATE if closed?
    super
  end

  def session_id
    client_id.session_id
  end

  def session_passwd
    client_id.passwd
  end

protected
  def barf_unless_running!
    @start_stop_mutex.synchronize do
      raise ShuttingDownException unless (@_running and not @_closed)
      yield
    end
  end

  def setup_dispatch_thread!
    @dispatcher = Thread.new do
      while running?
        begin                     # calling user code, so protect ourselves
          dispatch_next_callback
        rescue Exception => e
          $stderr.puts "Error in dispatch thread, #{e.class}: #{e.message}\n" << e.backtrace.map{|n| "\t#{n}"}.join("\n")
        end
      end
    end
  end

  # TODO: Make all global puts configurable
  def get_default_global_watcher
    Proc.new { |args|
      logger.debug { "Ruby ZK Global CB called type=#{event_by_value(args[:type])} state=#{state_by_value(args[:state])}" }
      true
    }
  end
end

