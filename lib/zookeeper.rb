# Ruby wrapper for the Zookeeper C API

require 'thread'
require 'monitor'
require 'forwardable'
require 'logger'

module Zookeeper
  # establishes the namespace
end

require File.expand_path('../zookeeper/core_ext', __FILE__)

silence_warnings do
  require 'backports'
end

require_relative 'zookeeper/monitor'
require_relative 'zookeeper/forked'
require_relative 'zookeeper/latch'
require_relative 'zookeeper/acls'
require_relative 'zookeeper/constants'
require_relative 'zookeeper/exceptions'
require_relative 'zookeeper/continuation'
require_relative 'zookeeper/common'
require_relative 'zookeeper/callbacks'
require_relative 'zookeeper/stat'
require_relative 'zookeeper/client_methods'

# ok, now we construct the client

require_relative 'zookeeper/client'

module Zookeeper
  include Constants

  unless defined?(@@logger)
    @@logger = Logger.new($stderr).tap { |l| l.level = ENV['ZOOKEEPER_DEBUG'] ? Logger::DEBUG : Logger::ERROR } 
  end

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
require_relative 'zookeeper/compatibility'

if ENV['ZKRB_DEBUG']
  Zookeeper.debug_level = Zookeeper::Constants::ZOO_LOG_LEVEL_DEBUG
end

