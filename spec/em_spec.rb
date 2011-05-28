require File.expand_path('../spec_helper', __FILE__)
require 'zookeeper/em_client'

gem 'evented-spec', '~> 0.4.1'
require 'evented-spec'


describe 'ZookeeperEM' do
  before do
    @zk = ZookeeperEM.new('localhost:2181')
  end

  describe 'selectable_io' do
    it %[should return an IO object] do
      @zk.selectable_io.should be_instance_of(IO)
    end

    it %[should not be closed] do
      @zk.selectable_io.should_not be_closed
    end

    before do
      @data_cb = ZookeeperCallbacks::DataCallback.new do
        $stderr.puts "cb called: #{@data_cb.inspect}"
      end
    end

    it %[should be read-ready if there's an event waiting] do
      @zk.get(:path => "/", :callback => @data_cb)

      r, *_ = IO.select([@zk.selectable_io], [], [], 2)

      r.should be_kind_of(Array)
    end

    it %[should not be read-ready if there's no event] do
      # there's always an initial event after connect

      events = 0

      while true
        r, *_ = IO.select([@zk.selectable_io], [], [], 0.2)

        break unless r

        h = @zk.get_next_event(false)
        @zk.selectable_io.read(1)

        events += 1

        h.should be_kind_of(Hash)
        $stderr.puts h
      end

      events.should == 1
    end
  end

end


