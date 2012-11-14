module Zookeeper
  TEST_LOG_PATH = File.expand_path('../../../test.log', __FILE__)

  def self.setup_test_logger
    log =
      if (ENV['ZOOKEEPER_DEBUG'] || ENV['ZKRB_DEBUG'])
        ::Logger.new(STDERR)
      else
        ::Logger.new(TEST_LOG_PATH)
      end

    log.level = ::Logger::DEBUG

    Zookeeper::Logger.wrapped_logger = log
  end
end

Zookeeper.setup_test_logger

module SpecGlobalLogger
  extend self

  def logger
    @spec_global_logger ||= Zookeeper::Logger::ForwardingLogger.for(Zookeeper::Logger.wrapped_logger, 'spec')
  end

  # sets the log level to FATAL for the duration of the block
  def mute_logger
    zk_log = Zookeeper::Logger.wrapped_logger

    orig_level, zk_log.level = zk_log.level, ::Logger::FATAL
    orig_zk_level, Zookeeper.debug_level = Zookeeper.debug_level, Zookeeper::Constants::ZOO_LOG_LEVEL_ERROR
    yield
  ensure
    zk_log.level = orig_zk_level
  end
end

