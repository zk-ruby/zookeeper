require 'shared/all_success_return_values'

shared_examples_for "connection" do

  before :each do
    ensure_node(zk, path, data)
  end

  after :each do
    ensure_node(zk, path, data)
  end

  after :all do
    logger.warn "running shared examples after :all"

    with_open_zk(connection_string) do |z|
      rm_rf(z, path)
    end
  end

  # unfortunately, we can't test w/o exercising other parts of the driver, so
  # if "set" is broken, this test will fail as well (but whaddyagonnado?)
  describe :get do
    describe :sync, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @rv = zk.get(:path => path)
      end

      it %[should return the data] do
        @rv[:data].should == data
      end

      it %[should return a stat] do
        @rv[:stat].should_not be_nil
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
      end
    end

    describe :sync_watch, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @event = nil
        @watcher = Zookeeper::Callbacks::WatcherCallback.new

        @rv = zk.get(:path => path, :watcher => @watcher, :watcher_context => path) 
      end

      it %[should return the data] do
        @rv[:data].should == data
      end

      it %[should set a watcher on the node] do
        # test the watcher by changing node data
        zk.set(:path => path, :data => 'blah')[:rc].should be_zero

        wait_until(1.0) { @watcher.completed? }

        @watcher.path.should == path
        @watcher.context.should == path
        @watcher.should be_completed
        @watcher.type.should == Zookeeper::ZOO_CHANGED_EVENT
      end
    end

    describe :async, :async => true do
      before do
        @cb = Zookeeper::Callbacks::DataCallback.new

        @rv = zk.get(:path => path, :callback => @cb, :callback_context => path)
        wait_until(1.0) { @cb.completed? }
        @cb.should be_completed
      end

      it_should_behave_like "all success return values"

      it %[should have a return code of ZOK] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should have the stat object in the callback] do
        @cb.stat.should_not be_nil
        @cb.stat.should be_kind_of(Zookeeper::Stat)
      end

      it %[should have the data] do
        @cb.data.should == data
      end
    end

    describe :async_watch, :async => true, :method => :get, :watch => true do
      it_should_behave_like "all success return values"

      before do
        logger.debug { "-----------------> MAKING ASYNC GET REQUEST WITH WATCH <--------------------" }
        @cb = Zookeeper::Callbacks::DataCallback.new
        @watcher = Zookeeper::Callbacks::WatcherCallback.new

        @rv = zk.get(:path => path, :callback => @cb, :callback_context => path, :watcher => @watcher, :watcher_context => path)
        wait_until(1.0) { @cb.completed? }
        @cb.should be_completed
        logger.debug { "-----------------> ASYNC GET REQUEST WITH WATCH COMPLETE <--------------------" }
      end

      it %[should have the stat object in the callback] do
        @cb.stat.should_not be_nil
        @cb.stat.should be_kind_of(Zookeeper::Stat)
      end

      it %[should have the data] do
        @cb.data.should == data
      end

      it %[should have a return code of ZOK] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should set a watcher on the node] do
        zk.set(:path => path, :data => 'blah')[:rc].should be_zero

        wait_until(2) { @watcher.completed? }

        @watcher.should be_completed

        @watcher.path.should == path
        @watcher.context.should == path
      end
    end

    describe 'bad arguments' do
      it %[should barf with a BadArguments error] do
        lambda { zk.get(:bad_arg => 'what!?') }.should raise_error(Zookeeper::Exceptions::BadArguments)
      end
    end
  end   # get

  describe :set do
    before do
      @new_data = "Four score and \007 years ago"
      @stat = zk.stat(:path => path)[:stat]
    end

    describe :sync, :sync => true do
      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.set(:path => path, :data => @new_data)
        end

        it %[should return the new stat] do
          @rv[:stat].should_not be_nil
          @rv[:stat].should be_kind_of(Zookeeper::Stat)
          @rv[:stat].version.should > @stat.version
        end
      end

      describe 'with current version' do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.set(:path => path, :data => @new_data, :version => @stat.version)
        end

        it %[should return the new stat] do
          @rv[:stat].should_not be_nil
          @rv[:stat].should be_kind_of(Zookeeper::Stat)
          @rv[:stat].version.should > @stat.version
        end
      end

      describe 'with outdated version' do
        before do
          # need to do a couple of sets to ramp up the version
          3.times { |n| @stat = zk.set(:path => path, :data => "#{@new_data}#{n}")[:stat] }

          @rv = zk.set(:path => path, :data => @new_data, :version => 0)
        end

        it %[should have a return code of ZBADVERSION] do
          @rv[:rc].should == Zookeeper::ZBADVERSION
        end

        it %[should return a stat with !exists] do
          @rv[:stat].exists.should be_false
        end
      end

      describe 'error' do
        it %[should barf if the data size is too large], :input_size => true do
          large_data = '0' * (1024 ** 2)

          lambda { zk.set(:path => path, :data => large_data) }.should raise_error(Zookeeper::Exceptions::DataTooLargeException)
        end
      end
    end   # sync

    describe :async, :async => true do
      before do
        @cb = Zookeeper::Callbacks::StatCallback.new
      end

      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.set(:path => path, :data => @new_data, :callback => @cb, :callback_context => path)

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
          @rv = zk.set(:path => path, :data => @new_data, :callback => @cb, :callback_context => path, :version => @stat.version)

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
          3.times { |n| @stat = zk.set(:path => path, :data => "#{@new_data}#{n}")[:stat] }

          @rv = zk.set(:path => path, :data => @new_data, :callback => @cb, :callback_context => path, :version => 0)

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

      describe 'error' do
        it %[should barf if the data size is too large], :input_size => true do
          large_data = '0' * (1024 ** 2)

          lambda { zk.set(:path => path, :data => large_data, :callback => @cb, :callback_context => path) }.should raise_error(Zookeeper::Exceptions::DataTooLargeException)
        end
      end

    end # async
  end # set

  describe :add_auth do
    it %[should return ZOK if everything goes swimingly] do
      result = zk.add_auth(:scheme => 'digest', :cert => 'test_user:test_password')

      rv = result[:rc]

      # gahhh, this shouldn't be like this.... :P
      rv = rv.respond_to?(:intValue) ? rv.intValue : rv

      rv.should == Zookeeper::ZOK
    end
  end

  describe :get_children do
    before do
      @children = %w[child0 child1 child2]

      @children.each do |name|
        zk.create(:path => "#{path}/#{name}", :data => name)
      end
    end

    after do
      @children.each do |name|
        zk.delete(:path => "#{path}/#{name}")
      end
    end

    describe :sync, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @rv = zk.get_children(:path => path)
      end

      it %[should have an array of names of the children] do
        @rv[:children].should be_kind_of(Array)
        @rv[:children].length.should == 3
        @rv[:children].sort.should == @children.sort 
      end

      # "Three shall be the number of the counting, and the number of the counting shall be 3"

      it %[should have a stat object whose num_children is 3] do
        @rv[:stat].should_not be_nil
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
        @rv[:stat].num_children.should == 3
      end
    end

    describe :sync_watch, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @addtl_child = 'child3'

        @watcher = Zookeeper::Callbacks::WatcherCallback.new

        @rv = zk.get_children(:path => path, :watcher => @watcher, :watcher_context => path)
      end

      after do
        zk.delete(:path => "#{path}/#{@addtl_child}")
      end

      it %[should have an array of names of the children] do
        @rv[:children].should be_kind_of(Array)
        @rv[:children].length.should == 3
        @rv[:children].sort.should == @children.sort 
      end

      it %[should have a stat object whose num_children is 3] do
        @rv[:stat].should_not be_nil
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
        @rv[:stat].num_children.should == 3
      end

      it %[should set a watcher for children on the node] do
        @watcher.should_not be_completed

        zk.create(:path => "#{path}/#{@addtl_child}", :data => '')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == path
        @watcher.context.should == path
        @watcher.type.should == Zookeeper::ZOO_CHILD_EVENT
      end
    end

    describe :async, :async => true do
      it_should_behave_like "all success return values"

      before do
        @cb = Zookeeper::Callbacks::StringsCallback.new
        @rv = zk.get_children(:path => path, :callback => @cb, :callback_context => path)

        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      it %[should succeed] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should return an array of children] do
        @cb.children.should be_kind_of(Array)
        @cb.children.length.should == 3
        @cb.children.sort.should == @children.sort 
      end

      it %[should have a stat object whose num_children is 3] do
        @cb.stat.should_not be_nil
        @cb.stat.should be_kind_of(Zookeeper::Stat)
        @cb.stat.num_children.should == 3
      end
    end

    describe :async_watch, :async => true do
      it_should_behave_like "all success return values"

      before do
        @addtl_child = 'child3'

        @watcher = Zookeeper::Callbacks::WatcherCallback.new
        @cb = Zookeeper::Callbacks::StringsCallback.new

        @rv = zk.get_children(:path => path, :watcher => @watcher, :watcher_context => path, :callback => @cb, :callback_context => path)
        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      after do
        zk.delete(:path => "#{path}/#{@addtl_child}")
      end

      it %[should succeed] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should return an array of children] do
        @cb.children.should be_kind_of(Array)
        @cb.children.length.should == 3
        @cb.children.sort.should == @children.sort 
      end

      it %[should have a stat object whose num_children is 3] do
        @cb.stat.should_not be_nil
        @cb.stat.should be_kind_of(Zookeeper::Stat)
        @cb.stat.num_children.should == 3
      end

      it %[should set a watcher for children on the node] do
        @watcher.should_not be_completed

        zk.create(:path => "#{path}/#{@addtl_child}", :data => '')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == path
        @watcher.context.should == path
        @watcher.type.should == Zookeeper::ZOO_CHILD_EVENT
      end
    end
  end

  describe :child_watcher_behavior do
    describe :async_watch, :async => true do
      it_should_behave_like "all success return values"

      before do
        @watcher = Zookeeper::Callbacks::WatcherCallback.new
        @cb = Zookeeper::Callbacks::StringsCallback.new

        @rv = zk.get_children(:path => path, :watcher => @watcher, :watcher_context => path, :callback => @cb, :callback_context => path)
        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      it %[should fire the watcher when the node has been deleted] do
        @watcher.should_not be_completed

        zk.delete(:path => path)[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == path
        @watcher.context.should == path
        @watcher.type.should == Zookeeper::ZOO_DELETED_EVENT
      end
    end
  end


  # NOTE: the jruby version of stat on non-existent node will have a
  # return_code of 0, but the C version will have a return_code of -101
  describe :stat do
    describe :sync, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @rv = zk.stat(:path => path)
      end

      it %[should have a stat object] do
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
      end
    end

    describe :sync_watch, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @watcher = Zookeeper::Callbacks::WatcherCallback.new

        @rv = zk.stat(:path => path, :watcher => @watcher, :watcher_context => path)
      end

      it %[should have a stat object] do
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
      end

      it %[should set a watcher for data changes on the node] do
        @watcher.should_not be_completed

        zk.set(:path => path, :data => 'skunk')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == path
        @watcher.context.should == path
        @watcher.type.should == Zookeeper::ZOO_CHANGED_EVENT
      end
    end

    describe :async, :async => true do
      it_should_behave_like "all success return values"

      before do
        @cb = Zookeeper::Callbacks::StatCallback.new
        @rv = zk.stat(:path => path, :callback => @cb, :callback_context => path)

        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      it %[should succeed] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should have a stat object] do
        @cb.stat.should be_kind_of(Zookeeper::Stat)
      end
    end

    describe :async_watch, :async => true do
      it_should_behave_like "all success return values"

      before do
        @addtl_child = 'child3'

        @watcher = Zookeeper::Callbacks::WatcherCallback.new

        @cb = Zookeeper::Callbacks::StatCallback.new
        @rv = zk.stat(:path => path, :callback => @cb, :callback_context => path, :watcher => @watcher, :watcher_context => path)

        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      after do
        zk.delete(:path => "#{path}/#{@addtl_child}")
      end

      it %[should succeed] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should have a stat object] do
        @cb.stat.should be_kind_of(Zookeeper::Stat)
      end

      it %[should set a watcher for data changes on the node] do
        @watcher.should_not be_completed

        zk.set(:path => path, :data => 'skunk')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == path
        @watcher.context.should == path
        @watcher.type.should == Zookeeper::ZOO_CHANGED_EVENT
      end
    end
  end   # stat

  describe :create do
    before do
      # remove the path set up by the global 'before' block
      zk.delete(:path => path)
    end

    describe :sync, :sync => true do
      describe 'error' do
        it %[should barf if the data size is too large], :input_size => true do
          large_data = '0' * (1024 ** 2)

          lambda { zk.create(:path => path, :data => large_data) }.should raise_error(Zookeeper::Exceptions::DataTooLargeException)
        end
      end

      describe :default_flags do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.create(:path => path)
        end

        it %[should return the path that was set] do
          @rv[:path].should == path
        end

        it %[should have created a permanent node] do
          st = zk.stat(:path => path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should == 0
        end
      end

      describe :ephemeral do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.create(:path => path, :ephemeral => true)
        end

        it %[should return the path that was set] do
          @rv[:path].should == path
        end

        it %[should have created a ephemeral node] do
          st = zk.stat(:path => path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should_not be_zero
        end
      end

      describe :sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = path
          @rv         = zk.create(:path => path, :sequence => true)
          @s_path     = @rv[:path]    # make sure this gets cleaned up
        end

        after do
          zk.delete(:path => @s_path)
        end

        it %[should return the path that was set] do
          @rv[:path].should_not == @orig_path
        end

        it %[should have created a permanent node] do
          st = zk.stat(:path => @s_path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should be_zero
        end
      end

      describe :ephemeral_sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = path
          @rv         = zk.create(:path => path, :sequence => true, :ephemeral => true)
          @s_path     = @rv[:path]    # make sure this gets cleaned up
        end

        after do
          zk.delete(:path => @s_path)
        end

        it %[should return the path that was set] do
          @rv[:path].should_not == @orig_path
        end

        it %[should have created an ephemeral node] do
          st = zk.stat(:path => @s_path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should_not be_zero
        end
      end

      describe :acl do
        it %[should work] do
          pending "need to write acl tests"
        end
      end
    end

    describe :async, :async => true do
      before do
        @cb = Zookeeper::Callbacks::StringCallback.new
      end

      describe :default_flags do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.create(:path => path, :callback => @cb, :callback_context => path)
          wait_until(2) { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @cb.path.should == path
        end

        it %[should have created a permanent node] do
          st = zk.stat(:path => path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should == 0
        end
      end

      describe 'error' do
        it %[should barf if the data size is too large], :input_size => true do
          large_data = '0' * (1024 ** 2)

          lambda do
            zk.create(:path => path, :data => large_data, :callback => @cb, :callback_context => path)
          end.should raise_error(Zookeeper::Exceptions::DataTooLargeException)
        end
      end


      describe :ephemeral do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.create(:path => path, :ephemeral => true, :callback => @cb, :callback_context => path)
          wait_until(2) { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @cb.path.should == path
        end

        it %[should have created a ephemeral node] do
          st = zk.stat(:path => path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should_not be_zero
        end
      end

      describe :sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = path
          @rv         = zk.create(:path => path, :sequence => true, :callback => @cb, :callback_context => path)

          wait_until(2) { @cb.completed? }
          @cb.should be_completed

          @s_path = @cb.path
        end

        after do
          zk.delete(:path => @s_path)
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @cb.path.should_not == @orig_path
        end

        it %[should have created a permanent node] do
          st = zk.stat(:path => @s_path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should be_zero
        end
      end

      describe :ephemeral_sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = path
          @rv         = zk.create(:path => path, :sequence => true, :ephemeral => true, :callback => @cb, :callback_context => path)
          path       = @rv[:path]    # make sure this gets cleaned up

          wait_until(2) { @cb.completed? }
          @cb.should be_completed
          @s_path = @cb.path
        end

        after do
          zk.delete(:path => @s_path)
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @s_path.should_not == @orig_path
        end

        it %[should have created an ephemeral node] do
          st = zk.stat(:path => @s_path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should_not be_zero
        end
      end # ephemeral_sequence
    end # async
  end # create

  describe :delete do
    describe :sync, :sync => true do
      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          zk.create(:path => path)
          @rv = zk.delete(:path => path)
        end

        it %[should have deleted the node] do
          zk.stat(:path => path)[:stat].exists.should be_false
        end
      end

      describe 'with current version' do
        it_should_behave_like "all success return values"

        before do
          zk.create(:path => path)

          @stat = zk.stat(:path => path)[:stat]
          @stat.exists.should be_true

          @rv = zk.delete(:path => path, :version => @stat.version)
        end

        it %[should have deleted the node] do
          zk.stat(:path => path)[:stat].exists.should be_false
        end
      end

      describe 'with old version' do
        before do
          3.times { |n| @stat = zk.set(:path => path, :data => n.to_s)[:stat] }

          @rv = zk.delete(:path => path, :version => 0)
        end

        it %[should have a return code of ZBADVERSION] do
          @rv[:rc].should == Zookeeper::ZBADVERSION
        end
      end
    end # sync

    describe :async, :async => true do
      before do
        @cb = Zookeeper::Callbacks::VoidCallback.new
      end

      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          @rv = zk.delete(:path => path, :callback => @cb, :callback_context => path)
          wait_until { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a success return_code] do
          @cb.return_code.should == Zookeeper::ZOK
        end

        it %[should have deleted the node] do
          zk.stat(:path => path)[:stat].exists.should be_false
        end
      end

      describe 'with current version' do
        it_should_behave_like "all success return values"

        before do
          @stat = zk.stat(:path => path)[:stat]
          @rv   = zk.delete(:path => path, :version => @stat.version, :callback => @cb, :callback_context => path)
          wait_until { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a success return_code] do
          @cb.return_code.should == Zookeeper::ZOK
        end

        it %[should have deleted the node] do
          zk.stat(:path => path)[:stat].exists.should be_false
        end
      end

      describe 'with old version' do
        before do
          3.times { |n| @stat = zk.set(:path => path, :data => n.to_s)[:stat] }

          @rv = zk.delete(:path => path, :version => 0, :callback => @cb, :callback_context => path)
          wait_until { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a return code of ZBADVERSION] do
          @cb.return_code.should == Zookeeper::ZBADVERSION
        end
      end
    end # async
  end # delete

  describe :get_acl do
    describe :sync, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @rv = zk.get_acl(:path => path)
      end

      it %[should return a stat for the path] do
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
      end

      it %[should return the acls] do
        acls = @rv[:acl]
        acls.should be_kind_of(Array)
        h = acls.first

        h.should be_kind_of(Hash)

        h[:perms].should == Zookeeper::ZOO_PERM_ALL
        h[:id][:scheme].should == 'world'
        h[:id][:id].should == 'anyone'
      end
    end

    describe :async, :async => true do
      it_should_behave_like "all success return values"

      before do
        @cb = Zookeeper::Callbacks::ACLCallback.new
        @rv = zk.get_acl(:path => path, :callback => @cb, :callback_context => path)

        wait_until(2) { @cb.completed? }
        @cb.should be_completed
      end

      it %[should return a stat for the path] do
        @cb.stat.should be_kind_of(Zookeeper::Stat)
      end

      it %[should return the acls] do
        acls = @cb.acl
        acls.should be_kind_of(Array)

        acl = acls.first
        acl.should be_kind_of(Zookeeper::ACLs::ACL)

        acl.perms.should == Zookeeper::ZOO_PERM_ALL

        acl.id.scheme.should == 'world'
        acl.id.id.should == 'anyone'
      end
    end
  end

  describe :set_acl do
    before do
      @perms = 5
      @new_acl = [Zookeeper::ACLs::ACL.new(:perms => @perms, :id => Zookeeper::Constants::ZOO_ANYONE_ID_UNSAFE)]
      pending("No idea how to set ACLs")
    end

    describe :sync, :sync => true do
      it_should_behave_like "all success return values"

      before do
        @rv = zk.set_acl(:path => path, :acl => @new_acl)
      end
    end
  end

  describe :session_id do
    it %[should return the session_id as a Fixnum] do
      zk.session_id.should be_kind_of(Integer)
    end
  end

  describe :session_passwd do
    it %[should return the session passwd as a String] do
      zk.session_passwd.should be_kind_of(String)
    end
  end

  describe :sync, :sync => true do
    describe :success do
      it_should_behave_like "all success return values"

      before do
        @cb = Zookeeper::Callbacks::StringCallback.new
        @rv = zk.sync(:path => path, :callback => @cb)

        wait_until(2) { @cb.completed }
        @cb.should be_completed
      end
    end

    describe :errors do
      it %[should barf with BadArguments if :callback is not given] do
        lambda { zk.sync(:path => path) }.should raise_error(Zookeeper::Exceptions::BadArguments)
      end
    end
  end

  describe :event_dispatch_thread? do
    it %[should return true when called on the event dispatching thread] do
      @result = nil

      cb = lambda do |hash|
        @result = zk.event_dispatch_thread?
      end

      @rv = zk.sync(:path => path, :callback => cb)

      wait_until(2) { @result == true }.should be_true
    end

    it %[should return false when not on the event dispatching thread] do
      zk.event_dispatch_thread?.should_not be_true
    end
  end

  describe :close do
    describe 'from the event dispatch thread' do
      it %[should not deadlock] do

        evil_cb = lambda do |*|
          logger.debug { "calling close event_dispatch_thread? #{zk.event_dispatch_thread?}" }
          zk.close
        end

        zk.stat(:path => path, :callback => evil_cb)

        wait_until { zk.closed? }
        zk.should be_closed
      end
    end
  end

  unless defined?(::JRUBY_VERSION)
    describe 'fork protection' do
      it %[should raise an InheritedConnectionError if the current Process.pid is different from the one that created the client] do
        pid = Process.pid
        begin
          Process.stub(:pid => -1)
          lambda { zk.stat(:path => path) }.should raise_error(Zookeeper::Exceptions::InheritedConnectionError)
        ensure
          # ensure we reset this, only want it to fail during the test
          Process.stub(:pid => pid)
        end
      end
    end
  end
end

