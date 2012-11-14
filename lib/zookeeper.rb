# Ruby wrapper for the Zookeeper C API

require 'thread'
require 'monitor'
require 'forwardable'
require 'logger'
require 'benchmark'

module Zookeeper
  ZOOKEEPER_ROOT = File.expand_path('../..', __FILE__)

  # require a path relative to the lib directory
  # this is to avoid monkeying explicitly with $LOAD_PATH
  #
  # @private
  def self.require_lib(*relpaths)
    relpaths.each do |relpath|
      require File.join(ZOOKEEPER_ROOT, 'lib', relpath)
    end
  end

  # require a path that's relative to ZOOKEEPER_ROOT
  # @private
  def self.require_root(*relpaths)
    relpaths.each do |relpath|
      require File.join(ZOOKEEPER_ROOT, relpath)
    end
  end
end

Zookeeper.require_lib(
  'zookeeper/core_ext',
  'zookeeper/monitor',
  'zookeeper/logger',
  'zookeeper/logger/forwarding_logger',
  'zookeeper/forked',
  'zookeeper/latch',
  'zookeeper/acls',
  'zookeeper/constants',
  'zookeeper/exceptions',
  'zookeeper/continuation',
  'zookeeper/common',
  'zookeeper/request_registry',
  'zookeeper/callbacks',
  'zookeeper/stat',
  'zookeeper/client_methods'
)

# ok, now we construct the client
Zookeeper.require_lib 'zookeeper/client'

module Zookeeper
  include Constants
  #::Logger.new($stderr).tap { |l| l.level = ENV['ZOOKEEPER_DEBUG'] ? ::Logger::DEBUG : ::Logger::ERROR } 
  #
  
  @@logger = nil unless defined?(@@logger)
  
  def self.logger
    @@logger
  end

  def self.logger=(logger)
    @@logger = logger
  end

  # @private
  def self.deprecation_warnings?
    @deprecation_warnings = true if @deprecation_warnings.nil?
  end

  # set this to false to mute Zookeeper related deprecation warnings...
  # __AT YOUR PERIL__
  def self.deprecation_warnings=(v)
    @deprecation_warnings = v
  end

  # @private
  def self.deprecation_warning(warning)
    Kernel.warn(warning) if deprecation_warnings?
  end

  # for expert use only. set the underlying debug level for the C layer, has no
  # effect in java
  #
  # @private
  def self.set_debug_level(val)
    if defined?(CZookeeper)
      CZookeeper.set_debug_level(val.to_i)
    end
  end

  # @private
  def self.get_debug_level
    if defined?(CZookeeper)
      CZookeeper.get_debug_level
    end
  end

  class << self
    # @private
    alias :debug_level= :set_debug_level
    
    # @private
    alias :debug_level :get_debug_level
  end
end

# just for first test, get rid of this soon
Zookeeper.require_lib 'zookeeper/compatibility'

if ENV['ZKRB_DEBUG']
  Zookeeper.debug_level = Zookeeper::Constants::ZOO_LOG_LEVEL_DEBUG
end

