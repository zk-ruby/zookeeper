require 'java'
require 'thread'
require 'rubygems'

gem 'slyphon-log4j', '= 1.2.15'
gem 'slyphon-zookeeper_jar', '= 3.3.4'

require 'log4j'
require 'zookeeper_jar'

# The low-level wrapper-specific methods for the Java lib,
# subclassed by the top-level Zookeeper class
class ZookeeperBase
  include Java
  include ZookeeperCommon
  include ZookeeperConstants
  include ZookeeperCallbacks
  include ZookeeperExceptions
  include ZookeeperACLs
  include ZookeeperStat

  JZK   = org.apache.zookeeper
  JZKD  = org.apache.zookeeper.data
  Code  = JZK::KeeperException::Code

  ANY_VERSION = -1
  DEFAULT_SESSION_TIMEOUT = 10_000

  ZKRB_GLOBAL_CB_REQ = -1 unless defined?(ZKRB_GLOBAL_CB_REQ)

  JZKD::Stat.class_eval do
    MEMBERS = [:version, :czxid, :mzxid, :ctime, :mtime, :cversion, :aversion, :ephemeralOwner, :dataLength, :numChildren, :pzxid]
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
      raise TypeError, "acl must be a ZookeeperACLs::ACL not #{acl.inspect}" unless acl.kind_of?(ZookeeperACLs::ACL)
      id = org.apache.zookeeper.data.Id.new(acl.id.scheme.to_s, acl.id.id.to_s)
      new(acl.perms.to_i, id)
    end

    def to_hash
      { :perms => getPerms, :id => getId.to_hash }
    end
  end

  JZK::WatchedEvent.class_eval do
    def to_hash
      { :type => getType.getIntValue, :state => getState.getIntValue, :path => getPath }
    end
  end

  # used for internal dispatching
  module JavaCB #:nodoc:
    class Callback
      attr_reader :req_id

      def initialize(req_id)
        @req_id = req_id
      end

    protected
      def logger
        Zookeeper.logger
      end
    end

    class DataCallback < Callback
      include JZK::AsyncCallback::DataCallback

      def processResult(rc, path, queue, data, stat)
        logger.debug { "#{self.class.name}#processResult rc: #{rc}, req_id: #{req_id}, path: #{path}, queue: #{queue.inspect}, data: #{data.inspect}, stat: #{stat.inspect}" }

        hash = {
          :rc     => rc,
          :req_id => req_id,
          :path   => path,
          :data   => (data && String.from_java_bytes(data)),
          :stat   => (stat && stat.to_hash),
        }

#         if rc == Zookeeper::ZOK
#           hash.merge!({
#             :data   => String.from_java_bytes(data),
#             :stat   => stat.to_hash,
#           })
#         end

        queue.push(hash)
      end
    end

    class StringCallback < Callback
      include JZK::AsyncCallback::StringCallback

      def processResult(rc, path, queue, str)
        logger.debug { "#{self.class.name}#processResult rc: #{rc}, req_id: #{req_id}, path: #{path}, queue: #{queue.inspect}, str: #{str.inspect}" }
        queue.push(:rc => rc, :req_id => req_id, :path => path, :string => str)
      end
    end

    class StatCallback < Callback
      include JZK::AsyncCallback::StatCallback

      def processResult(rc, path, queue, stat)
        logger.debug { "#{self.class.name}#processResult rc: #{rc.inspect}, req_id: #{req_id}, path: #{path.inspect}, queue: #{queue.inspect}, stat: #{stat.inspect}" }
        queue.push(:rc => rc, :req_id => req_id, :stat => (stat and stat.to_hash), :path => path)
      end
    end

    class Children2Callback < Callback
      include JZK::AsyncCallback::Children2Callback

      def processResult(rc, path, queue, children, stat)
        logger.debug { "#{self.class.name}#processResult rc: #{rc}, req_id: #{req_id}, path: #{path}, queue: #{queue.inspect}, children: #{children.inspect}, stat: #{stat.inspect}" }
        hash = {
          :rc       => rc, 
          :req_id   => req_id, 
          :path     => path, 
          :strings  => (children && children.to_a), 
          :stat     => (stat and stat.to_hash),
        }

        queue.push(hash)
      end
    end

    class ACLCallback < Callback
      include JZK::AsyncCallback::ACLCallback
      
      def processResult(rc, path, queue, acl, stat)
        logger.debug { "ACLCallback#processResult rc: #{rc.inspect}, req_id: #{req_id}, path: #{path.inspect}, queue: #{queue.inspect}, acl: #{acl.inspect}, stat: #{stat.inspect}" }
        a = Array(acl).map { |a| a.to_hash }
        queue.push(:rc => rc, :req_id => req_id, :path => path, :acl => a, :stat => (stat && stat.to_hash))
      end
    end

    class VoidCallback < Callback
      include JZK::AsyncCallback::VoidCallback

      def processResult(rc, path, queue)
        logger.debug { "#{self.class.name}#processResult rc: #{rc}, req_id: #{req_id}, queue: #{queue.inspect}" }
        queue.push(:rc => rc, :req_id => req_id, :path => path)
      end
    end

    class WatcherCallback < Callback
      include JZK::Watcher

      def initialize(event_queue)
        @event_queue = event_queue
        super(ZookeeperBase::ZKRB_GLOBAL_CB_REQ)
      end

      def process(event)
        logger.debug { "WatcherCallback got event: #{event.to_hash.inspect}" }
        hash = event.to_hash.merge(:req_id => req_id)
        @event_queue.push(hash)
      end
    end
  end

  attr_reader :event_queue

  def reopen(timeout=10, watcher=nil)
#     watcher ||= @default_watcher

    @mutex.synchronize do
      # flushes all outstanding watcher reqs.
      @watcher_reqs.clear
      set_default_global_watcher

      replace_jzk!
      wait_until_connected
    end

    state
  end

  def wait_until_connected(timeout=10)
    time_to_stop = timeout ? (Time.now + timeout) : nil

    until connected? or (time_to_stop and Time.now > time_to_stop)
      Thread.pass
    end

    connected?
  end

  def initialize(host, timeout=10, watcher=nil, options={})
    @host = host
    @event_queue = QueueWithPipe.new
    @current_req_id = 0

    @mutex = Monitor.new
    @dispatch_shutdown_cond = @mutex.new_cond

    @watcher_reqs = {}
    @completion_reqs = {}
    @_running = nil
    @_closed  = false
    @options = {}

    @default_watcher = (watcher || get_default_global_watcher)

    # allows connected-state handlers to be registered before 
    yield self if block_given?

    reopen(timeout, watcher)
    return nil unless connected?
    @_running = true
    setup_dispatch_thread!
  end

  def close
    @mutex.synchronize do
      return if @_closed
      @_closed = true    # these are probably unnecessary
      @_running = false

      stop_dispatch_thread!
      @jzk.close if @jzk
    end
  end

  def state
    @mutex.synchronize { @jzk.state }
  end

  def connected?
    state == JZK::ZooKeeper::States::CONNECTED
  end

  def connecting?
    state == JZK::ZooKeeper::States::CONNECTING
  end

  def associating?
    state == JZK::ZooKeeper::States::ASSOCIATING
  end

  def running?
    @_running
  end

  def closed?
    @_closed
  end

  def self.set_debug_level(*a)
    # IGNORED IN JRUBY
  end

  def set_debug_level(*a)
    # IGNORED IN JRUBY
  end

  def get(req_id, path, callback, watcher)
    handle_keeper_exception do
      watch_cb = watcher ? create_watcher(req_id, path) : false

      if callback
        jzk.getData(path, watch_cb, JavaCB::DataCallback.new(req_id), event_queue)
        [Code::Ok, nil, nil]    # the 'nil, nil' isn't strictly necessary here
      else # sync
        stat = JZKD::Stat.new
        data = String.from_java_bytes(jzk.getData(path, watch_cb, stat))

        [Code::Ok, data, stat.to_hash]
      end
    end
  end

  def set(req_id, path, data, callback, version)
    handle_keeper_exception do
      version ||= ANY_VERSION

      if callback
        jzk.setData(path, data.to_java_bytes, version, JavaCB::StatCallback.new(req_id), event_queue)
        [Code::Ok, nil]
      else
        stat = jzk.setData(path, data.to_java_bytes, version).to_hash
        [Code::Ok, stat]
      end
    end
  end

  def get_children(req_id, path, callback, watcher)
    handle_keeper_exception do
      watch_cb = watcher ? create_watcher(req_id, path) : false

      if callback
        jzk.getChildren(path, watch_cb, JavaCB::Children2Callback.new(req_id), event_queue)
        [Code::Ok, nil, nil]
      else
        stat = JZKD::Stat.new
        children = jzk.getChildren(path, watch_cb, stat)
        [Code::Ok, children.to_a, stat.to_hash]
      end
    end
  end

  def create(req_id, path, data, callback, acl, flags)
    handle_keeper_exception do
      acl   = Array(acl).map{ |a| JZKD::ACL.from_ruby_acl(a) }
      mode  = JZK::CreateMode.fromFlag(flags)

      data ||= ''

      if callback
        jzk.create(path, data.to_java_bytes, acl, mode, JavaCB::StringCallback.new(req_id), event_queue)
        [Code::Ok, nil]
      else
        new_path = jzk.create(path, data.to_java_bytes, acl, mode)
        [Code::Ok, new_path]
      end
    end
  end

  def sync(req_id, path)
    handle_keeper_exception do
      jzk.sync(path, JavaCB::VoidCallback.new(req_id), event_queue)
      Code::Ok
    end
  end

  def delete(req_id, path, version, callback)
    handle_keeper_exception do
      if callback
        jzk.delete(path, version, JavaCB::VoidCallback.new(req_id), event_queue)
      else
        jzk.delete(path, version)
      end

      Code::Ok
    end
  end

  def set_acl(req_id, path, acl, callback, version)
    handle_keeper_exception do
      logger.debug { "set_acl: acl #{acl.inspect}" }
      acl = Array(acl).flatten.map { |a| JZKD::ACL.from_ruby_acl(a) }
      logger.debug { "set_acl: converted #{acl.inspect}" }

      if callback
        jzk.setACL(path, acl, version, JavaCB::ACLCallback.new(req_id), event_queue)
      else
        jzk.setACL(path, acl, version)
      end

      Code::Ok
    end
  end

  def exists(req_id, path, callback, watcher)
    handle_keeper_exception do
      watch_cb = watcher ? create_watcher(req_id, path) : false

      if callback
        jzk.exists(path, watch_cb, JavaCB::StatCallback.new(req_id), event_queue)
        [Code::Ok, nil, nil]
      else
        stat = jzk.exists(path, watch_cb)
        [Code::Ok, (stat and stat.to_hash)]
      end
    end
  end

  def get_acl(req_id, path, callback)
    handle_keeper_exception do
      stat = JZKD::Stat.new

      if callback
        logger.debug { "calling getACL, path: #{path.inspect}, stat: #{stat.inspect}" } 
        jzk.getACL(path, stat, JavaCB::ACLCallback.new(req_id), event_queue)
        [Code::Ok, nil, nil]
      else
        acls = jzk.getACL(path, stat).map { |a| a.to_hash }
        
        [Code::Ok, Array(acls).map{|m| m.to_hash}, stat.to_hash]
      end
    end
  end

  def assert_open
    # XXX don't know how to check for valid session state!
    raise ZookeeperException::NotConnected unless connected?
  end

  # set the watcher object/proc that will receive all global events (such as session/state events)
  #---
  # XXX: this code needs to be duplicated from ext/zookeeper_base.rb because
  # it's called from the initializer, and because of the C impl. we can't have
  # the two decend from a common base, and a module wouldn't work
  def set_default_global_watcher
    @mutex.synchronize do
      @watcher_reqs[ZKRB_GLOBAL_CB_REQ] = { :watcher => @default_watcher, :watcher_context => nil }
    end
  end

  def session_id
    jzk.session_id
  end

  def session_passwd
    jzk.session_passwd.to_s
  end

  protected
    def jzk
      @mutex.synchronize { @jzk }
    end

    def handle_keeper_exception
      yield
    rescue JZK::KeeperException => e
      e.cause.code.intValue
    end

    def call_type(callback, watcher)
      if callback
        watcher ? :async_watch : :async
      else
        watcher ? :sync_watch : :sync
      end
    end
   
    def create_watcher(req_id, path)
      logger.debug { "creating watcher for req_id: #{req_id} path: #{path}" }
      lambda do |event|
        logger.debug { "watcher for req_id #{req_id}, path: #{path} called back" }
        h = { :req_id => req_id, :type => event.type.int_value, :state => event.state.int_value, :path => path }
        event_queue.push(h)
      end
    end

    # method to wait until block passed returns true or timeout (default is 10 seconds) is reached 
    def wait_until(timeout=10, &block)
      time_to_stop = Time.now + timeout
      until yield do 
        break if Time.now > time_to_stop
        sleep 0.1
      end
    end

    # TODO: Make all global puts configurable
    def get_default_global_watcher
      Proc.new { |args|
        logger.debug { "Ruby ZK Global CB called type=#{event_by_value(args[:type])} state=#{state_by_value(args[:state])}" }
        true
      }
    end

  private
    def replace_jzk!
      orig_jzk = @jzk
      @jzk = JZK::ZooKeeper.new(@host, DEFAULT_SESSION_TIMEOUT, JavaCB::WatcherCallback.new(event_queue))
    ensure
      orig_jzk.close if orig_jzk
    end
end


