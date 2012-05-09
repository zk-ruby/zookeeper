require 'spec_helper'

unless defined?(::JRUBY_VERSION)
  describe %[forked connection] do
    let(:path) { "/_zktest_" }
    let(:pids_root) { "#{path}/pids" }
    let(:data) { "underpants" } 
    let(:connection_string) { Zookeeper.default_cnx_str }

    def process_alive?(pid)
      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH
      false
    end

    before do
      if defined?(::Rubinius)
        pending("this test is currently broken in rbx")
      elsif ENV['TRAVIS']
        pending("this test is currently hanging in travis")
      else
        @zk = Zookeeper.new(connection_string)
        rm_rf(@zk, path)
      end
    end

    after do
      if @pid and process_alive?(@pid)
        Process.kill('TERM', @pid)
        p Process.wait2(@pid)
      end

      @zk.close if @zk and !@zk.closed?
      with_open_zk(connection_string) { |z| rm_rf(z, path) }
    end

    it %[should do the right thing and not fail] do
      @zk.wait_until_connected

      mkdir_p(@zk, pids_root)

      # the parent's pid path
      @zk.create(:path => "#{pids_root}/#{$$}", :data => $$.to_s)

      @latch = Zookeeper::Latch.new
      @event = nil

      cb = proc do |h|
        logger.debug { "watcher called back: #{h.inspect}" }
        @event = h
        @latch.release
      end

      @zk.stat(:path => "#{pids_root}/child", :watcher => cb)

      @pid = fork do
        logger.debug { "reopening connection in child: #{$$}" }
        @zk.reopen
        logger.debug { "creating path" }
        rv = @zk.create(:path => "#{pids_root}/child", :data => $$.to_s)
        logger.debug { "created path #{rv}" }
        @zk.close

        logger.debug { "close finished" }
        exit!(0)
      end

      logger.debug { "waiting on child #{@pid}" }

      @latch.await until @event 
      p @event

      _, status = Process.wait2(@pid)

      status.should be_success
    end
  end
end

