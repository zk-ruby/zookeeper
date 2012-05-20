module Zookeeper
  TEST_LOG_PATH = File.expand_path('../../../test.log', __FILE__)
end

layout = Logging.layouts.pattern(
  :pattern => '%.1l, [%d #%p] %30.30c{2}:  %m\n',
  :date_pattern => '%Y-%m-%d %H:%M:%S.%6N' 
)

appender = (ENV['ZOOKEEPER_DEBUG'] || ENV['ZKRB_DEBUG']) ? Logging.appenders.stderr : Logging.appenders.file(Zookeeper::TEST_LOG_PATH)
appender.layout = layout

%w[spec Zookeeper].each do |name|
  ::Logging.logger[name].tap do |log|
    log.appenders = [appender]
    log.level = :debug
  end
end

module SpecGlobalLogger
  def logger
    @spec_global_logger ||= ::Logging.logger['spec']
  end

  # sets the log level to FATAL for the duration of the block
  def mute_logger
    zk_log = Logging.logger['Zookeeper']
    orig_level, zk_log.level = zk_log.level, :off
    orig_zk_level, Zookeeper.debug_level = Zookeeper.debug_level, Zookeeper::Constants::ZOO_LOG_LEVEL_ERROR
    yield
  ensure
    zk_log.level = orig_zk_level
  end
end

