require 'java'
require 'thread'

# require 'rubygems'
# gem 'slyphon-log4j', '= 1.2.15'
# gem 'zk-ruby-zookeeper_jar', "= #{Zookeeper::DRIVER_VERSION}"

require 'log4j'
require 'zookeeper_jar'


# XXX: reindent this WHOLE FILE later
module Zookeeper

# The low-level wrapper-specific methods for the Java lib,
# subclassed by the top-level Zookeeper class
class JavaBase
  include Java
  include Common
  include Constants
  include Callbacks
  include Exceptions
  include ACLs
  include Logger

  JZK   = org.apache.zookeeper
  JZKD  = org.apache.zookeeper.data
  Code  = JZK::KeeperException::Code

  ANY_VERSION = -1
  DEFAULT_SESSION_TIMEOUT = 10_000

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
      raise TypeError, "acl must be a Zookeeper::ACLs::ACL not #{acl.inspect}" unless acl.kind_of?(Zookeeper::ACLs::ACL)
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
  # @private
  module JavaCB
    class Callback
      include Logger

      attr_reader :req_id

      def initialize(req_id)
        @req_id = req_id
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
      include Zookeeper::Constants

      attr_reader :client

      def initialize(event_queue, opts={})
        @event_queue = event_queue
        @client = opts[:client]
        super(ZKRB_GLOBAL_CB_REQ)
      end

      def process(event)
        hash = event.to_hash
        logger.debug { "WatcherCallback got event: #{hash.inspect}" }

        if client && (hash[:type] == ZOO_SESSION_EVENT) && (hash[:state] == ZOO_CONNECTED_STATE)
          logger.debug { "#{self.class}##{__method__} notifying client of connected state!" }
          client.notify_connected! 
        end
        
        hash = event.to_hash.merge(:req_id => req_id)
        @event_queue.push(hash)
      end
    end
  end

  attr_reader :event_queue

  def reopen(timeout=10, watcher=nil, opts = {})
#     watcher ||= @default_watcher

    @mutex.synchronize do
      @req_registry.clear_watchers!

      replace_jzk!(opts)
      wait_until_connected
    end

    state
  end

  def wait_until_connected(timeout=10)
    @connected_latch.await(timeout) unless connected?
    connected?
  end

  def initialize(host, timeout=10, watcher=nil, options={})
    @host = host
    @event_queue = QueueWithPipe.new

    watcher ||= get_default_global_watcher()

    @req_registry = RequestRegistry.new(watcher)

    @mutex = Monitor.new
    @dispatch_shutdown_cond = @mutex.new_cond
    @connected_latch = Latch.new

    @_running = nil
    @_closed  = false
    @options = {}


    # allows connected-state handlers to be registered before 
    yield self if block_given?

    reopen(timeout, nil, options)
    return nil unless connected?
    @_running = true
    setup_dispatch_thread!
  end

  def close
    shutdown_thread = Thread.new do
      @mutex.synchronize do
        unless @_closed
          @_closed = true    # these are probably unnecessary
          @_running = false

          stop_dispatch_thread!
          @jzk.close if @jzk
        end
      end
    end

    shutdown_thread.join unless event_dispatch_thread?
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

        value = jzk.getData(path, watch_cb, stat)
        data = String.from_java_bytes(value) unless value.nil?
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

  def add_auth(req_id, scheme, cert)
    handle_keeper_exception do
      jzk.addAuthInfo(scheme, cert.to_java_bytes)
      Code::Ok
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
    raise NotConnected unless connected?
  end

  def session_id
    jzk.session_id
  end

  def session_passwd
    jzk.session_passwd.to_s
  end

  # called from watcher when we are connected
  # @private
  def notify_connected!
    @connected_latch.release
  end

  def pause_before_fork_in_parent
    # this is a no-op in java-land
  end

  def resume_after_fork_in_parent
    # this is a no-op in java-land
  end

  private
    def jzk
      @mutex.synchronize { @jzk }
    end

    # java exceptions are not wrapped anymore in JRuby 1.7+
    if JRUBY_VERSION >= '1.7.0'
      def handle_keeper_exception
        yield
      rescue JZK::KeeperException => e
        # code is an enum and always set -> we don't need any additional checks here
        e.code.intValue
      end
    else
      def handle_keeper_exception
        yield
      rescue JZK::KeeperException => e
        if e.respond_to?(:cause) and e.cause and e.cause.respond_to?(:code) and e.cause.code and e.cause.code.respond_to?(:intValue)
          e.cause.code.intValue
        else
          raise e # dunno what happened, just raise it
        end
      end
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
        ev_type, ev_state = event.type.int_value, event.state.int_value

        logger.debug { "watcher for req_id #{req_id}, path: #{path} called back" }

        h = { :req_id => req_id, :type => ev_type, :state => ev_state, :path => path }
        event_queue.push(h)
      end
    end

    def get_default_global_watcher
      Proc.new { |args|
        logger.debug { "Ruby ZK Global CB called type=#{event_by_value(args[:type])} state=#{state_by_value(args[:state])}" }
        true
      }
    end

    def replace_jzk!(opts = {})
      orig_jzk = @jzk
      if opts.has_key?(:session_id) && opts.has_key(:session_passwd)
        @jzk = JZK::ZooKeeper.new(@host, DEFAULT_SESSION_TIMEOUT, JavaCB::WatcherCallback.new(event_queue, :client => self), opts.fetch(:session_id), opts.fetch(:session_passwd).to_java_bytes)
      else
        @jzk = JZK::ZooKeeper.new(@host, DEFAULT_SESSION_TIMEOUT, JavaCB::WatcherCallback.new(event_queue, :client => self))
      end
    ensure
      orig_jzk.close if orig_jzk
    end
end
end

