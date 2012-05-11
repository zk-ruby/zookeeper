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

    def wait_until_connected(timeout=2)
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

      it %[should be able to re-establish a session] do
        wait_until_connected.should be_true
        
        orig_czk = @czk

        client_id = orig_czk.client_id.dup
        client_id.session_id.should be > 0

        # something is fucked with the 'equal?' matcher
        client_id.passwd.object_id.should_not == orig_czk.client_id.passwd.object_id


        orig_czk.close
        @czk = Zookeeper::CZookeeper.new(Zookeeper.default_cnx_str, @event_queue, :client_id => client_id)

        wait_until_connected.should be_true

        @czk.client_id.session_id.should == client_id.session_id
      end

      describe :after_connected do
        before do
          wait_until_connected.should be_true
        end

        it %[should have a connection event after being connected] do
          event = wait_until(2) { @event_queue.pop }
          event.should be
          event[:req_id].should == Zookeeper::Common::ZKRB_GLOBAL_CB_REQ
          event[:type].should   == Zookeeper::Constants::ZOO_SESSION_EVENT
          event[:state].should  == Zookeeper::Constants::ZOO_CONNECTED_STATE
        end
      end
    end
  end
end

