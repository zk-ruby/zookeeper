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
  include ZookeeperConstants
  include ZookeeperExceptions
  include ZookeeperACLs
  include ZookeeperStat

  JZK   = org.apache.zookeeper
  JZKD  = org.apache.zookeeper.data
  Code  = JZK::KeeperException::Code

  ANY_VERSION = -1
  DEFAULT_SESSION_TIMEOUT = 10_000

  JZKD::Stat.class_eval do
    MEMBERS = [:version, :exists, :czxid, :mzxid, :ctime, :mtime, :cverzion, :aversion, :ephemeralOwner, :dataLength, :numChildren, :pzxid]
    def to_hash
      MEMBERS.inject({}) { |h,k| h[k] = __send__(k); h }
    end
  end

  JZKD::Id.class_eval do
    def to_hash
      { :scheme => getScheme, :id => getId }
    end
  end

  JZKD::ACL.class_eval do
    def self.from_ruby_acl(acl)
      id = org.apache.zookeeper.data.Id.new(acl.id.scheme.to_s, acl.id.id.to_s)
      new(perms.to_i, id)
    end

    def to_hash
      { :perms => getPerms, :id => getId.to_hash }
    end
  end

  # used for internal dispatching
  module JavaCB #:nodoc:
    class Callback
      attr_reader :req_id

      def initialize(req_id)
        @req_id = req_id
      end
    end

    class DataCallback < Callback
      include JZK::AsyncCallback::DataCallback

      def processResult(rc, path, queue, data, stat)
        queue.push({
          :rc     => rc,
          :req_id => req_id,
          :path   => path,
          :data   => String.from_java_bytes(data),
          :stat   => stat.to_hash,
        })
      end
    end

    class StringCallback < Callback
      include JZKD::AsyncCallback::StringCallback

      def processResult(rc, path, queue, str)
        queue.push(:rc => rc, :req_id => req_id, :path => path, :string => str)
      end
    end

    class StatCallback < Callback
      include JZKD::AsyncCallback::StatCallback

      def processResult(rc, path, queue, stat)
        queue.push(:rc => rc, :req_id => req_id, :stat => stat.to_hash, :path => path)
      end
    end

    class Children2Callback < Callback
      include JZKD::AsyncCallback::Children2Callback

      def processResult(rc, path, queue, children, stat)
        queue.push(:rc => rc, :req_id => req_id, :path => path, :strings => children.to_a, :stat => stat.to_hash)
      end
    end

    class ACLCallback < Callback
      include JZKD::AsyncCallback::ACLCallback
      
      def processResult(rc, path, queue, acl, stat)
        queue.push(:rc => rc, :req_id => req_id, :path => path, :acl => acl.to_hash, :stat => stat.to_hash)
      end
    end

    class VoidCallback < Callback
      include JZKD::AsyncCallback::VoidCallback

      def processResult(rc, path, queue)
        queue.push(:rc => rc, :req_id => req_id, :path => path)
      end
    end
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

  def get(req_id, path, callback, watcher)
    handle_keeper_exception do
      watch_cb = watcher ? create_watcher(req_id, path) : false

      if callback
        @jzk.getData(path, watch_cb, JavaCB::DataCallback.new(req_id), @event_queue)
        [Code::Ok, nil, nil]    # the 'nil, nil' isn't strictly necessary here
      else # sync
        stat = JZKD::Stat.new
        data = String.from_java_bytes(@jzk.getData(path, watch_cb, stat))

        [Code::Ok, data, stat.to_hash]
      end
    end
  end

  def set(req_id, path, data, callback, version)
    handle_keeper_exception do
      version ||= ANY_VERSION

      if callback
        @jzk.setData(path, data.to_java_bytes, version, JavaCB::StatCallback.new(req_id), @event_queue)
        [Code::Ok, nil]
      else
        stat = @jzk.setData(path, data.to_java_bytes, version).to_hash
        [Code::Ok, stat]
      end
    end
  end

  def get_children(req_id, path, callback, watcher)
    handle_keeper_exception do
      watch_cb = watcher ? create_watcher(req_id, path) : false

      if callback
        @jzk.getChildren(path, watch_cb, JavaCB::Children2Callback.new(req_id), @event_queue)
        [Code::Ok, nil, nil]
      else
        stat = JZKD::Stat.new
        children = @jzk.getChildren(path, watch_cb, stat)
        [Code::Ok, children.to_a, stat.to_hash]
      end
    end
  end

  def stat(req_id, path, callback, watcher)
    handle_keeper_exception do
      watch_cb = watcher ? create_watcher(req_id, path) : false

      if callback
        @jzk.exists(path, watch_cb, JavaCB::StatCallback.new(req_id), @event_queue)
        [Code::Ok, nil, nil]
      else
        stat = @jzk.getChildren(path, watch_cb)
        [Code::Ok, children.to_a, stat.to_hash]
      end
    end
  end

  def create(req_id, path, data, callback, acl, flags)
    handle_keeper_exception do
      acl   = Array(acl).map{ |a| JZKD::ACL.from_ruby_acl(a) }
      mode  = JZK::CreateMode.fromFlag(flags)

      if callback
        @jzk.create(path, data.to_java_bytes, acl, mode, callback, @event_queue)
        [Code::Ok, nil]
      else
        new_path = @jzk.create(path, data.to_java_bytes, acl, mode)
        [Code::Ok, new_path]
      end
    end
  end

  def delete(req_id, path, version, callback)
    handle_keeper_exception do
      if callback
        @jzk.delete(path, version, JavaCB::VoidCallback.new(req_id), @event_queue)
      else
        @jzk.delete(path, version)
      end

      Code::Ok
    end
  end

  def set_acl(req_id, path, acl, callback, version)
    handle_keeper_exception do
      acl = Array(acl).map{ |a| JZKD::ACL.from_ruby_acl(a) }

      if callback
        @jzk.setACL(path, acl, version, JavaCB::ACLCallback.new(req_id), @event_queue)
      else
        @jzk.setACL(path, acl, version)
      end

      Code::Ok
    end
  end

  def get_acl(req_id, path, acl, callback)
    handle_keeper_exception do
      stat = JZKD::Stat.new

      if callback
        @jzk.getACL(path, stat, JavaCB::ACLCallback.new(req_id), @event_queue)
        [Code::Ok, nil, nil]
      else
        acls = @jzk.getACL(path, stat).map { |a| a.to_hash }
        [Code::Ok, acls, stat.to_hash]
      end
    end
  end

  def assert_open
    # XXX don't know how to check for valid session state!
    raise ZookeeperException::ConnectionClosed unless connected?
  end

  protected
    def handle_keeper_exception
      yield
    rescue JZK::KeeperException => e
      [e.code.intValue, nil, nil]
    end

    def call_type(callback, watcher)
      if callback
        watcher ? :async_watch : :async
      else
        watcher ? :sync_watch : :sync
      end
    end
   
    def create_watcher(req_id, path)
      lambda do |event|
        h = { :req_id => req_id, :type => event.type.int_value, :state => event.state.int_value, :path => path }
        @event_queue.push(h)
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


