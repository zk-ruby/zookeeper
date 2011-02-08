require File.expand_path('../spec_helper', __FILE__) 

shared_examples_for "all return values" do
  it %[should have a return code of 0] do
    @rv[:rc].should be_zero
  end

  it %[should have a req_id integer] do
    @rv[:req_id].should be_kind_of(Integer)
  end
end

describe Zookeeper do
  # unfortunately, we can't test w/o exercising other parts of the driver, so
  # if "set" is broken, this test will fail as well (but whaddyagonnado?)
  describe :get do
    before do
      @path = "/_zktest_"
      @data = "underpants"

      @zk.create(:path => @path, :data => @data)
    end

    after do
      @zk.delete(:path => @path)
    end

    describe :sync do
      it_should_behave_like "all return values"

      before do
        @rv = @zk.get(:path => @path)
      end

      it %[should return the data] do
        @rv[:data].should == @data
      end

      it %[should return a stat] do
        @rv[:stat].should_not be_nil
        @rv[:stat].should be_kind_of(ZookeeperStat::Stat)
      end
    end

    describe :sync_watch do
      it_should_behave_like "all return values"

      before do
        @event = nil
        @watcher = Zookeeper::WatcherCallback.new

        @rv = @zk.get(:path => @path, :watcher => @watcher, :watcher_context => @path) 
      end

      it %[should return the data] do
        @rv[:data].should == @data
      end

      it %[should set a watcher on the node] do
        # test the watcher by changing node data
        @zk.set(:path => @path, :data => 'blah')[:rc].should be_zero

        wait_until { @watcher.completed? }

        @watcher.path.should == @path
        @watcher.context.should == @path
        @watcher.should be_completed
      end
    end

    describe :async do
      it_should_behave_like "all return values"

      before do
        @cb = Zookeeper::DataCallback.new

        @rv = @zk.get(:path => @path, :callback => @cb, :callback_context => @path)
        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      it %[should have the stat object in the callback] do
        @cb.stat.should_not be_nil
        @cb.stat.should be_kind_of(ZookeeperStat::Stat)
      end

      it %[should have the data] do
        @cb.data.should == @data
      end
    end

    describe :async_watch do
      it_should_behave_like "all return values"

      before do
        @cb = Zookeeper::DataCallback.new
        @watcher = Zookeeper::WatcherCallback.new

        @rv = @zk.get(:path => @path, :callback => @cb, :callback_context => @path, :watcher => @watcher, :watcher_context => @path)
        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      it %[should have the stat object in the callback] do
        @cb.stat.should_not be_nil
        @cb.stat.should be_kind_of(ZookeeperStat::Stat)
      end

      it %[should have the data] do
        @cb.data.should == @data
      end

      it %[should set a watcher on the node] do
        @zk.set(:path => @path, :data => 'blah')[:rc].should be_zero

        wait_until(2) { @watcher.completed? }

        @watcher.should be_completed

        @watcher.path.should == @path
        @watcher.context.should == @path
      end

    end
  end
end
