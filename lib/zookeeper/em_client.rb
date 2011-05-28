require 'zookeeper'
require 'eventmachine'

class ZookeeperEM < Zookeeper


  def close
    @_running = false
    wake_event_loop!
    super
  end

protected
  def setup_dispatch_thread!
    # no-op!
  end
end

