require 'thread'
require 'rubygems'

gem 'slyphon-log4j', '= 1.2.15'
gem 'slyphon-zookeeper_jar', '= 3.3.1'

require 'log4j'
require 'zookeeper_jar'


# The low-level wrapper-specific methods for the Java lib,
# subclassed by the top-level Zookeeper class
class ZookeeperBase
  include ZookeeperCommon
  include ZookeeperCallbacks
  include ZookeeperConstants
  include ZookeeperExceptions
  include ZookeeperACLs
  include ZookeeperStat

  JZK   = org.apache.zookeeper
  JZKD  = org.apache.zookeeper.data
  Code  = JZK::KeeperException::Code

  DEFAULT_SESSION_TIMEOUT = 10_000

  module JavaStatExt
    MEMBERS = [:version, :exists, :czxid, :mzxid, :ctime, :mtime, :cverzion, :aversion, :ephemeralOwner, :dataLength, :numChildren, :pzxid]
    def to_hash
      MEMBERS.inject({}) { |h,k| h[k] = __send__(k); h }
    end
  end

  JZKD::Stat.class_eval do
    include JavaStatExt
  end

  def reopen(timeout=10)
    @jzk = JZK::ZooKeeper.new(@host, DEFAULT_SESSION_TIMEOUT, JavaSilentWatcher.new)

    if timeout > 0
      time_to_stop = Time.now + timeout
      until connected?
        break if Time.now > time_to_stop
        sleep 0.1
      end
    end

    state
  end

  def initialize(host, timeout=10)
    @host = host
    @event_queue = Queue.new
    @current_req_id = 0
    @req_mutex = Mutex.new
    reopen(timeout)
    return nil unless connected?
  end

  def state
    @jzk.state
  end

  def connected?
    state == JZK::States::CONNECTED
  end

  def connecting?
    state == JZK::States::CONNECTING
  end

  def associating?
    state == JZK::States::ASSOCIATING
  end

  # 4 excpected call types: SYNC SYNC_WATCH ASYNC ASYNC_WATCH


  def get(req_id, path, callback, watcher)
    case call_type(callback, watcher)
    when :sync_watch
      stat = JZKD::Stat.new
      data = String.from_java_bytes(@jzk.getData(path, watcher, stat))

      [Code::Ok, data, stat.to_hash]
    when :async_watch
      @jzk.getData(path, watcher, callback, )
    when :sync
    when :async
    end
  end

  def assert_open
    # XXX don't know how to check for valid session state!
    raise ZookeeperException::ConnectionClosed unless connected?
  end

  protected
    def call_type(callback, watcher)
      if callback
        watcher ? :async_watch : :async
      else
        watcher ? :sync_watch : :sync
      end
    end

private
  def setup_dispatch_thread!
    @dispatcher = Thread.new do
      Thread.current[:running] = true

      while Thread.current[:running]
        dispatch_next_callback 
      end
    end
  end

end


