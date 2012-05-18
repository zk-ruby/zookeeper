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

    LBORDER = ('-' * 35) << '< '
    RBORDER = ' >' << ('-' * 35) 

    def mark(thing)
      logger << "\n#{LBORDER}#{thing}#{RBORDER}\n\n"
    end

    before do
      mark "BEFORE: START"
      if defined?(::Rubinius)
        pending("this test is currently broken in rbx")
#       elsif ENV['TRAVIS']
#         pending("this test is currently hanging in travis")
      else
        @zk = Zookeeper.new(connection_string)
        rm_rf(@zk, path)
      end
      mark "BEFORE: END"
    end

    after do
      mark "AFTER: START"

      if @pid and process_alive?(@pid)
        begin
          Process.kill('KILL', @pid)
          p Process.wait2(@pid)
        rescue Errno::ESRCH
        end
      end

      @zk.close if @zk and !@zk.closed?
      with_open_zk(connection_string) { |z| rm_rf(z, path) }

      mark "AFTER: END"
    end

    def wait_for_child_safely(pid, timeout=5)
      time_to_stop = Time.now + timeout

      until Time.now > time_to_stop
        if a = Process.wait2(@pid, Process::WNOHANG)
          return a.last
        else
          sleep(0.01)
        end
      end

      nil
    end

    it %[should do the right thing and not fail] do
      mark "TEST: START"

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

      @zk.pause_before_fork_in_parent

      mark "FORK"

      @pid = fork do
        logger.debug { "reopening connection in child: #{$$}" }
        @zk.reopen
        logger.debug { "creating path" }
        rv = @zk.create(:path => "#{pids_root}/child", :data => $$.to_s)
        logger.debug { "created path #{rv[:path]}" }
        @zk.close

        logger.debug { "close finished" }
        exit!(0)
      end

      @zk.resume_after_fork_in_parent

      event_waiter_th = Thread.new do
        @latch.await(5) unless @event 
        @event
      end

      logger.debug { "waiting on child #{@pid}" }

      status = wait_for_child_safely(@pid)
      raise "Child process did not exit, likely hung"  unless status

      status.should_not be_signaled
      status.should be_success

      event_waiter_th.join(5).should == event_waiter_th
      @event.should_not be_nil
    end
  end
end
