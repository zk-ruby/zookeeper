require 'spec_helper'

describe Zookeeper do
  describe :initialize, 'with watcher block' do
    before do
      @events = []
      @watch_block = lambda do |hash| 
        logger.debug "watch_block: #{hash.inspect}"
        @events << hash
      end

      @zk = Zookeeper.new(Zookeeper.default_cnx_str, 10, @watch_block)

      wait_until(2) { @zk.connected? }
      @zk.should be_connected
      logger.debug "connected!"

      wait_until(2) { !@events.empty? }
      logger.debug "got events!"
    end

    after do
      @zk.close if @zk.connected?
    end

    it %[should receive initial connection state events] do
      @events.should_not be_empty
      @events.length.should == 1
      @events.first[:state].should == Zookeeper::ZOO_CONNECTED_STATE
    end

    it %[should receive disconnection events] do
      pending "the C driver doesn't appear to deliver disconnection events (?)"
      @events.clear
      @zk.close
      wait_until(2) { !@events.empty? }
      @events.should_not be_empty
    end
  end
end

