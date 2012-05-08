$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))
$LOAD_PATH.unshift(File.expand_path('../../ext', __FILE__))
$LOAD_PATH.uniq!

require 'rubygems'

release_ops_path = File.expand_path('../../releaseops/lib', __FILE__)

if File.exists?(release_ops_path)
  require File.join(release_ops_path, 'releaseops')
  ReleaseOps::SimpleCov.maybe_start
end

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


RSpec.configure do |config|
  config.mock_with :rspec
  config.include Zookeeper::SpecHeleprs
  config.extend Zookeeper::SpecHeleprs

  if Zookeeper.spawn_zookeeper?
    require 'zk-server'

    config.before(:suite) do 
      Zookeeper.logger.debug { "Starting zookeeper service" }
      ZK::Server.run do |c|
        c.base_dir    = File.expand_path('../../.zkserver', __FILE__)
        c.client_port = Zookeeper.test_port
        c.force_sync  = false
        c.snap_count  = 1_000_000
      end
    end

    config.after(:suite) do
      Zookeeper.logger.debug { "stopping zookeeper service" }
      ZK::Server.shutdown
    end
  end
end

