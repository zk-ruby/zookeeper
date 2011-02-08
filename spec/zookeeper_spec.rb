require File.expand_path('../spec_helper', __FILE__) 

shared_examples_for "all success return values" do
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
      it_should_behave_like "all success return values"

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
      it_should_behave_like "all success return values"

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
      it_should_behave_like "all success return values"

      before do
        @cb = Zookeeper::DataCallback.new

        @rv = @zk.get(:path => @path, :callback => @cb, :callback_context => @path)
        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      it %[should have a return code of ZOK] do
        @cb.return_code.should == Zookeeper::ZOK
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
      it_should_behave_like "all success return values"

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

      it %[should have a return code of ZOK] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should set a watcher on the node] do
        @zk.set(:path => @path, :data => 'blah')[:rc].should be_zero

        wait_until(2) { @watcher.completed? }

        @watcher.should be_completed

        @watcher.path.should == @path
        @watcher.context.should == @path
      end
    end
  end   # get

  describe :set do
    before do
      @path = "/_zktest_"
      @orig_data = "underpants"
      @new_data = "Four score and \007 years ago"

      @zk.create(:path => @path, :data => @orig_data)
      @stat = @zk.stat(:path => @path)[:stat]
    end

    after do
      @zk.delete(:path => @path)
    end

    describe :sync do
      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.set(:path => @path, :data => @new_data)
        end

        it %[should return the new stat] do
          @rv[:stat].should_not be_nil
          @rv[:stat].should be_kind_of(ZookeeperStat::Stat)
          @rv[:stat].version.should > @stat.version
        end
      end

      describe 'with current version' do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.set(:path => @path, :data => @new_data, :version => @stat.version)
        end

        it %[should return the new stat] do
          @rv[:stat].should_not be_nil
          @rv[:stat].should be_kind_of(ZookeeperStat::Stat)
          @rv[:stat].version.should > @stat.version
        end
      end

      describe 'with outdated version' do
        before do
          # need to do a couple of sets to ramp up the version
          3.times { |n| @stat = @zk.set(:path => @path, :data => "#{@new_data}#{n}")[:stat] }

          @rv = @zk.set(:path => @path, :data => @new_data, :version => 0)
        end

        it %[should have a return code of ZBADVERSION] do
          @rv[:rc].should == Zookeeper::ZBADVERSION
        end

        it %[should return a stat with !exists] do
          @rv[:stat].exists.should be_false
        end
      end
    end   # sync

    describe :async do
      before do
        @cb = Zookeeper::StatCallback.new
      end

      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.set(:path => @path, :data => @new_data, :callback => @cb, :callback_context => @path)

          wait_until(2) { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have the stat in the callback] do
          @cb.stat.should_not be_nil
          @cb.stat.version.should > @stat.version
        end

        it %[should have a return code of ZOK] do
          @cb.return_code.should == Zookeeper::ZOK
        end
      end

      describe 'with current version' do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.set(:path => @path, :data => @new_data, :callback => @cb, :callback_context => @path, :version => @stat.version)

          wait_until(2) { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have the stat in the callback] do
          @cb.stat.should_not be_nil
          @cb.stat.version.should > @stat.version
        end

        it %[should have a return code of ZOK] do
          @cb.return_code.should == Zookeeper::ZOK
        end
      end

      describe 'with outdated version' do
        before do
          # need to do a couple of sets to ramp up the version
          3.times { |n| @stat = @zk.set(:path => @path, :data => "#{@new_data}#{n}")[:stat] }

          @rv = @zk.set(:path => @path, :data => @new_data, :callback => @cb, :callback_context => @path, :version => 0)

          wait_until(2) { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a return code of ZBADVERSION] do
          @cb.return_code.should == Zookeeper::ZBADVERSION
        end

        it %[should return a stat with !exists] do
          @cb.stat.exists.should be_false
        end
      end
    end
  end
end
