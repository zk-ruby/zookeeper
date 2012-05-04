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

  def ensure_node(zk, path, data)
    return if zk.closed?
    if zk.stat(:path => path)[:stat].exists?
      zk.set(:path => path, :data => data)
    else
      zk.create(:path => path, :data => data)
    end
  end

  def with_open_zk(host='localhost:2181')
    z = Zookeeper.new(host)
    yield z
  ensure
    if z
      unless z.closed?
        z.close

        wait_until do 
          begin
            !z.connected?
          rescue RuntimeError
            true
          end
        end
      end
    end
  end

  # this is not as safe as the one in ZK, just to be used to clean up
  # when we're the only one adjusting a particular path
  def rm_rf(z, path)
    z.get_children(:path => path).tap do |h|
      if h[:rc].zero?
        h[:children].each do |child|
          rm_rf(z, File.join(path, child))
        end
      elsif h[:rc] == Zookeeper::Exceptions::ZNONODE
        # no-op
      else
        raise "Oh noes! unexpected return value! #{h.inspect}"
      end
    end

    rv = z.delete(:path => path)

    unless (rv[:rc].zero? or rv[:rc] == Zookeeper::Exceptions::ZNONODE)
      raise "oh noes! failed to delete #{path}" 
    end

    path
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


