module Zookeeper
  module SpecHelpers
    class TimeoutError < StandardError; end
    include Zookeeper::Constants
    include Zookeeper::Logger

    def ensure_node(zk, path, data)
      return if zk.closed?
      if zk.stat(:path => path)[:stat].exists?
        zk.set(:path => path, :data => data)
      else
        zk.create(:path => path, :data => data)
      end
    end

    def with_open_zk(host=nil)
      z = Zookeeper.new(Zookeeper.default_cnx_str)
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
        elsif h[:rc] == ZNONODE
          # no-op
        else
          raise "Oh noes! unexpected return value! #{h.inspect}"
        end
      end

      rv = z.delete(:path => path)

      unless (rv[:rc].zero? or rv[:rc] == ZNONODE)
        raise "oh noes! failed to delete #{path}" 
      end

      path
    end

    def mkdir_p(zk, path)
      while true # loop because we can't retry
        h = zk.create(:path => path, :data => '')
        case h[:rc]
        when ZOK, ZNODEEXISTS
          return
        when ZNONODE
          parent = File.dirname(path)
          raise "WTF? we wound up trying to create '/', something is screwed!" if parent == '/'
          mkdir_p(zk, parent)
        end
      end
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
end
