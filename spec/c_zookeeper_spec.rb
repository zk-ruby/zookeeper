# tests the CZookeeper, obviously only available when running under MRI

unless defined?(::JRUBY_VERSION)
  require 'spec_helper'

  describe Zookeeper::CZookeeper do
    def pop_all_events
      [].tap do |rv|
        begin
          rv << @event_queue.pop(non_blocking=true)
        rescue ThreadError
        end
      end
    end

    def wait_until_connected(timeout=10)
      wait_until(timeout) { @czk.state == Zookeeper::Constants::ZOO_CONNECTED_STATE }
    end

    describe do
      before do
        @event_queue = Zookeeper::Common::QueueWithPipe.new
        @czk = Zookeeper::CZookeeper.new(Zookeeper.default_cnx_str, @event_queue)
      end

      after do
        @czk.close rescue Exception
        @event_queue.close rescue Exception
      end

      it %[should be in connected state within a reasonable amount of time] do
        wait_until_connected.should be_true
      end

      describe :after_connected do
        before do
          wait_until_connected.should be_true
        end

        it %[should have a connection event after being connected] do
          event = wait_until(10) { @event_queue.pop }
          event.should be
          event[:req_id].should == Zookeeper::Constants::ZKRB_GLOBAL_CB_REQ
          event[:type].should   == Zookeeper::Constants::ZOO_SESSION_EVENT
          event[:state].should  == Zookeeper::Constants::ZOO_CONNECTED_STATE
        end
      end
    end
  end
end

