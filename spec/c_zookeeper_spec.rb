# tests the CZookeeper, obviously only available when running under MRI
require 'spec_helper'

if Module.const_defined?(:CZookeeper)
  describe CZookeeper do
    def pop_all_events
      [].tap do |rv|
        begin
          rv << @event_queue.pop(non_blocking=true)
        rescue ThreadError
        end
      end
    end

    def wait_until_connected(timeout=2)
      wait_until(timeout) { @czk.state == ZookeeperConstants::ZOO_CONNECTED_STATE }
    end

    before do
      @event_queue = ZookeeperCommon::QueueWithPipe.new
      @czk = CZookeeper.new('localhost:2181', @event_queue)
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

      end
    end
  end
end

