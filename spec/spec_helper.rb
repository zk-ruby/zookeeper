$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))
$LOAD_PATH.unshift(File.expand_path('../../ext', __FILE__))
$LOAD_PATH.uniq!

require 'rubygems'

gem 'flexmock', '~> 0.8.11'

require 'flexmock'
require 'zookeeper'

Dir[File.expand_path('../support/**/*.rb', __FILE__)].sort.each { |f| require(f) }

if ENV['ZKRB_DEBUG']
  Zookeeper.logger = Logger.new($stderr).tap { |l| l.level = Logger::DEBUG }
  Zookeeper.set_debug_level(4)
else
  Zookeeper.logger = Logger.new(File.expand_path('../../test.log', __FILE__)).tap do |log|
    log.level = Logger::DEBUG
  end
end

if ENV['ZKRB_NOLOG']
  Zookeeper.logger.level = Logger::FATAL
  Zookeeper.set_debug_level(0)
end

module ZookeeperSpecHeleprs
  class TimeoutError < StandardError; end

  def logger
    Zookeeper.logger
  end

  # method to wait until block passed returns true or timeout (default is 10 seconds) is reached 
  # raises TiemoutError on timeout
  def wait_until(timeout=10)
    time_to_stop = Time.now + timeout
    while true
      rval = yield
      return rval if rval
      raise TimeoutError, "timeout of #{timeout}s exceeded" if Time.now > time_to_stop
      Thread.pass
    end
  end

  # inverse of wait_until
  def wait_while(timeout=10)
    time_to_stop = Time.now + timeout
    while true
      rval = yield
      return rval unless rval
      raise TimeoutError, "timeout of #{timeout}s exceeded" if Time.now > time_to_stop
      Thread.pass
    end
  end
end

RSpec.configure do |config|
  config.mock_with :flexmock
  config.include ZookeeperSpecHeleprs
  config.extend ZookeeperSpecHeleprs
end


