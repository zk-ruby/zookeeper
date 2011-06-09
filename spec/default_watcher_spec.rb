require File.expand_path('../spec_helper', __FILE__) 

describe Zookeeper do
  describe :initialize, 'with watcher block' do
    before do
      @events = []
      @watch_block = lambda do |hash| 
        $stderr.puts "watch_block: #{hash.inspect}"
        @events << hash
      end

      @zk = Zookeeper.new('localhost:2181', 10, @watch_block)

      wait_until(2) { @zk.connected? }
      @zk.should be_connected
      $stderr.puts "connected!"

      wait_until(2) { !@events.empty? }
      $stderr.puts "got events!"
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

