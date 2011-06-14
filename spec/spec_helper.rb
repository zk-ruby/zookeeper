$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))
$LOAD_PATH.unshift(File.expand_path('../../ext', __FILE__))
$LOAD_PATH.uniq!

require 'rubygems'

gem 'flexmock', '~> 0.8.11'

require 'flexmock'
require 'zookeeper'

Zookeeper.logger = Logger.new(File.expand_path('../../test.log', __FILE__)).tap do |log|
  log.level = Logger::DEBUG
end

def logger
  Zookeeper.logger
end


require 'rspec/core/formatters/progress_formatter'

module RSpec
  module Core
    module Formatters
      class ProgressFormatter
        def example_started(example)
          Zookeeper.logger.info(yellow("=====<([ #{example.full_description} ])>====="))
          super(example)
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.mock_with :flexmock
end


# method to wait until block passed returns true or timeout (default is 10 seconds) is reached 
def wait_until(timeout=10, &block)
  time_to_stop = Time.now + timeout
  until yield do 
    break if Time.now > time_to_stop
    sleep 0.3
  end
end


