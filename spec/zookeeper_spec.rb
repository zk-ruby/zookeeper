require File.expand_path('../spec_helper', __FILE__) 

shared_examples_for "all success return values" do
  it %[should have a return code of Zookeeper::ZOK] do
    @rv[:rc].should == Zookeeper::ZOK
  end

  it %[should have a req_id integer] do
    @rv[:req_id].should be_kind_of(Integer)
  end
end

describe Zookeeper do
  before do
    @path = "/_zktest_"
    @data = "underpants"

    @zk = Zookeeper.new('localhost:2181')

    # uncomment for driver debugging output
    #@zk.set_debug_level(Zookeeper::ZOO_LOG_LEVEL_DEBUG) unless defined?(::JRUBY_VERSION)

    @zk.create(:path => @path, :data => @data)
  end

  after do
    @zk.delete(:path => @path)
    @zk.close

    wait_until do 
      begin
        !@zk.connected?
      rescue RuntimeError
        true
      end
    end
  end

  # unfortunately, we can't test w/o exercising other parts of the driver, so
  # if "set" is broken, this test will fail as well (but whaddyagonnado?)
  describe :get do
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

        wait_until(1.0) { @watcher.completed? }

        @watcher.path.should == @path
        @watcher.context.should == @path
        @watcher.should be_completed
        @watcher.type.should == Zookeeper::ZOO_CHANGED_EVENT
      end
    end

    describe :async do
      it_should_behave_like "all success return values"

      before do
        @cb = Zookeeper::DataCallback.new

        @rv = @zk.get(:path => @path, :callback => @cb, :callback_context => @path)
        wait_until(1.0) { @cb.completed? }
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
        wait_until(1.0) { @cb.completed? }
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

    describe 'bad arguments' do
      it %[should barf with a BadArguments error] do
        lambda { @zk.get(:bad_arg => 'what!?') }.should raise_error(ZookeeperExceptions::ZookeeperException::BadArguments)
      end
    end
  end   # get

  describe :set do
    before do
      @new_data = "Four score and \007 years ago"
      @stat = @zk.stat(:path => @path)[:stat]
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

  describe :get_children do
    before do
      @children = %w[child0 child1 child2]

      @children.each do |name|
        @zk.create(:path => "#{@path}/#{name}", :data => name)
      end
    end

    after do
      @children.each do |name|
        @zk.delete(:path => "#{@path}/#{name}")
      end
    end

    describe :sync do
      it_should_behave_like "all success return values"

      before do
        @rv = @zk.get_children(:path => @path)
      end

      it %[should have an array of names of the children] do
        @rv[:children].should be_kind_of(Array)
        @rv[:children].length.should == 3
        @rv[:children].sort.should == @children.sort 
      end

      # "Three shall be the number of the counting, and the number of the counting shall be 3"

      it %[should have a stat object whose num_children is 3] do
        @rv[:stat].should_not be_nil
        @rv[:stat].should be_kind_of(ZookeeperStat::Stat)
        @rv[:stat].num_children.should == 3
      end
    end

    describe :sync_watch do
      it_should_behave_like "all success return values"

      before do
        @addtl_child = 'child3'

        @watcher = Zookeeper::WatcherCallback.new

        @rv = @zk.get_children(:path => @path, :watcher => @watcher, :watcher_context => @path)
      end

      after do
        @zk.delete(:path => "#{@path}/#{@addtl_child}")
      end

      it %[should have an array of names of the children] do
        @rv[:children].should be_kind_of(Array)
        @rv[:children].length.should == 3
        @rv[:children].sort.should == @children.sort 
      end

      it %[should have a stat object whose num_children is 3] do
        @rv[:stat].should_not be_nil
        @rv[:stat].should be_kind_of(ZookeeperStat::Stat)
        @rv[:stat].num_children.should == 3
      end

      it %[should set a watcher for children on the node] do
        @watcher.should_not be_completed

        @zk.create(:path => "#{@path}/#{@addtl_child}", :data => '')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == @path
        @watcher.context.should == @path
        @watcher.type.should == Zookeeper::ZOO_CHILD_EVENT
      end
    end

    describe :async do
      it_should_behave_like "all success return values"

      before do
        @cb = ZookeeperCallbacks::StringsCallback.new
        @rv = @zk.get_children(:path => @path, :callback => @cb, :callback_context => @path)

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
        @cb.stat.should be_kind_of(ZookeeperStat::Stat)
        @cb.stat.num_children.should == 3
      end
    end

    describe :async_watch do
      it_should_behave_like "all success return values"

      before do
        @addtl_child = 'child3'

        @watcher = Zookeeper::WatcherCallback.new
        @cb = ZookeeperCallbacks::StringsCallback.new

        @rv = @zk.get_children(:path => @path, :watcher => @watcher, :watcher_context => @path, :callback => @cb, :callback_context => @path)
        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      after do
        @zk.delete(:path => "#{@path}/#{@addtl_child}")
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
        @cb.stat.should be_kind_of(ZookeeperStat::Stat)
        @cb.stat.num_children.should == 3
      end

      it %[should set a watcher for children on the node] do
        @watcher.should_not be_completed

        @zk.create(:path => "#{@path}/#{@addtl_child}", :data => '')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == @path
        @watcher.context.should == @path
        @watcher.type.should == Zookeeper::ZOO_CHILD_EVENT
      end
    end
  end

  # NOTE: the jruby version of stat on non-existent node will have a
  # return_code of 0, but the C version will have a return_code of -101
  describe :stat do
    describe :sync do
      it_should_behave_like "all success return values"

      before do
        @rv = @zk.stat(:path => @path)
      end

      it %[should have a stat object] do
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
      end
    end

    describe :sync_watch do
      it_should_behave_like "all success return values"

      before do
        @watcher = Zookeeper::WatcherCallback.new

        @rv = @zk.stat(:path => @path, :watcher => @watcher, :watcher_context => @path)
      end

      it %[should have a stat object] do
        @rv[:stat].should be_kind_of(Zookeeper::Stat)
      end

      it %[should set a watcher for data changes on the node] do
        @watcher.should_not be_completed

        @zk.set(:path => @path, :data => 'skunk')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == @path
        @watcher.context.should == @path
        @watcher.type.should == Zookeeper::ZOO_CHANGED_EVENT
      end
    end

    describe :async do
      it_should_behave_like "all success return values"

      before do
        @cb = ZookeeperCallbacks::StatCallback.new
        @rv = @zk.stat(:path => @path, :callback => @cb, :callback_context => @path)

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

    describe :async_watch do
      it_should_behave_like "all success return values"

      before do
        @addtl_child = 'child3'

        @watcher = Zookeeper::WatcherCallback.new

        @cb = ZookeeperCallbacks::StatCallback.new
        @rv = @zk.stat(:path => @path, :callback => @cb, :callback_context => @path, :watcher => @watcher, :watcher_context => @path)

        wait_until { @cb.completed? }
        @cb.should be_completed
      end

      after do
        @zk.delete(:path => "#{@path}/#{@addtl_child}")
      end

      it %[should succeed] do
        @cb.return_code.should == Zookeeper::ZOK
      end

      it %[should have a stat object] do
        @cb.stat.should be_kind_of(Zookeeper::Stat)
      end

      it %[should set a watcher for data changes on the node] do
        @watcher.should_not be_completed

        @zk.set(:path => @path, :data => 'skunk')[:rc].should == Zookeeper::ZOK

        wait_until { @watcher.completed? }
        @watcher.should be_completed

        @watcher.path.should == @path
        @watcher.context.should == @path
        @watcher.type.should == Zookeeper::ZOO_CHANGED_EVENT
      end
    end
  end   # stat

  describe :create do
    before do
      # remove the path set up by the global 'before' block
      @zk.delete(:path => @path)
    end

    describe :sync do
      describe :default_flags do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.create(:path => @path)
        end

        it %[should return the path that was set] do
          @rv[:path].should == @path
        end

        it %[should have created a permanent node] do
          st = @zk.stat(:path => @path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should == 0
        end
      end

      describe :ephemeral do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.create(:path => @path, :ephemeral => true)
        end

        it %[should return the path that was set] do
          @rv[:path].should == @path
        end

        it %[should have created a ephemeral node] do
          st = @zk.stat(:path => @path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should_not be_zero
        end
      end

      describe :sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = @path
          @rv         = @zk.create(:path => @path, :sequence => true)
          @path       = @rv[:path]    # make sure this gets cleaned up
        end

        it %[should return the path that was set] do
          @rv[:path].should_not == @orig_path
        end

        it %[should have created a permanent node] do
          st = @zk.stat(:path => @path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should be_zero
        end
      end

      describe :ephemeral_sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = @path
          @rv         = @zk.create(:path => @path, :sequence => true, :ephemeral => true)
          @path       = @rv[:path]    # make sure this gets cleaned up
        end

        it %[should return the path that was set] do
          @rv[:path].should_not == @orig_path
        end

        it %[should have created an ephemeral node] do
          st = @zk.stat(:path => @path)
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

    describe :async do
      before do
        @cb = ZookeeperCallbacks::StringCallback.new
      end

      describe :default_flags do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.create(:path => @path, :callback => @cb, :callback_context => @path)
          wait_until(2) { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @cb.path.should == @path
        end

        it %[should have created a permanent node] do
          st = @zk.stat(:path => @path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should == 0
        end
      end

      describe :ephemeral do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.create(:path => @path, :ephemeral => true, :callback => @cb, :callback_context => @path)
          wait_until(2) { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @cb.path.should == @path
        end

        it %[should have created a ephemeral node] do
          st = @zk.stat(:path => @path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should_not be_zero
        end
      end

      describe :sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = @path
          @rv         = @zk.create(:path => @path, :sequence => true, :callback => @cb, :callback_context => @path)

          wait_until(2) { @cb.completed? }
          @cb.should be_completed

          @path = @cb.path
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @cb.path.should_not == @orig_path
        end

        it %[should have created a permanent node] do
          st = @zk.stat(:path => @path)
          st[:rc].should == Zookeeper::ZOK

          st[:stat].ephemeral_owner.should be_zero
        end
      end

      describe :ephemeral_sequence do
        it_should_behave_like "all success return values"

        before do
          @orig_path  = @path
          @rv         = @zk.create(:path => @path, :sequence => true, :ephemeral => true, :callback => @cb, :callback_context => @path)
          @path       = @rv[:path]    # make sure this gets cleaned up

          wait_until(2) { @cb.completed? }
          @cb.should be_completed
          @path = @cb.path
        end

        it %[should have a path] do
          @cb.path.should_not be_nil
        end

        it %[should return the path that was set] do
          @path.should_not == @orig_path
        end

        it %[should have created an ephemeral node] do
          st = @zk.stat(:path => @path)
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
  end

  describe :delete do
    describe :sync do
      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          @zk.create(:path => @path)
          @rv = @zk.delete(:path => @path)
        end

        it %[should have deleted the node] do
          @zk.stat(:path => @path)[:stat].exists.should be_false
        end
      end

      describe 'with current version' do
        it_should_behave_like "all success return values"

        before do
          @zk.create(:path => @path)

          @stat = @zk.stat(:path => @path)[:stat]
          @stat.exists.should be_true

          @rv = @zk.delete(:path => @path, :version => @stat.version)
        end

        it %[should have deleted the node] do
          @zk.stat(:path => @path)[:stat].exists.should be_false
        end
      end

      describe 'with old version' do
        before do
          3.times { |n| @stat = @zk.set(:path => @path, :data => n.to_s)[:stat] }

          @rv = @zk.delete(:path => @path, :version => 0)
        end

        it %[should have a return code of ZBADVERSION] do
          @rv[:rc].should == Zookeeper::ZBADVERSION
        end
      end
    end # sync

    describe :async do
      before do
        @cb = ZookeeperCallbacks::VoidCallback.new
      end

      describe 'without version' do
        it_should_behave_like "all success return values"

        before do
          @rv = @zk.delete(:path => @path, :callback => @cb, :callback_context => @path)
          wait_until { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a success return_code] do
          @cb.return_code.should == Zookeeper::ZOK
        end

        it %[should have deleted the node] do
          @zk.stat(:path => @path)[:stat].exists.should be_false
        end
      end

      describe 'with current version' do
        it_should_behave_like "all success return values"

        before do
          @stat = @zk.stat(:path => @path)[:stat]
          @rv   = @zk.delete(:path => @path, :version => @stat.version, :callback => @cb, :callback_context => @path)
          wait_until { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a success return_code] do
          @cb.return_code.should == Zookeeper::ZOK
        end

        it %[should have deleted the node] do
          @zk.stat(:path => @path)[:stat].exists.should be_false
        end
      end

      describe 'with old version' do
        before do
          3.times { |n| @stat = @zk.set(:path => @path, :data => n.to_s)[:stat] }

          @rv = @zk.delete(:path => @path, :version => 0, :callback => @cb, :callback_context => @path)
          wait_until { @cb.completed? }
          @cb.should be_completed
        end

        it %[should have a return code of ZBADVERSION] do
          @cb.return_code.should == Zookeeper::ZBADVERSION
        end
      end
    end
  end # delete

  describe :get_acl do
    describe :sync do
      it_should_behave_like "all success return values"

      before do
        @rv = @zk.get_acl(:path => @path)
      end

      it %[should return a stat for the path] do
        @rv[:stat].should be_kind_of(ZookeeperStat::Stat)
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

    describe :async do
      it_should_behave_like "all success return values"

      before do
        @cb = Zookeeper::ACLCallback.new
        @rv = @zk.get_acl(:path => @path, :callback => @cb, :callback_context => @path)

        wait_until(2) { @cb.completed? }
        @cb.should be_completed
      end

      it %[should return a stat for the path] do
        @cb.stat.should be_kind_of(ZookeeperStat::Stat)
      end

      it %[should return the acls] do
        acls = @cb.acl
        acls.should be_kind_of(Array)

        acl = acls.first
        acl.should be_kind_of(ZookeeperACLs::ACL)

        acl.perms.should == Zookeeper::ZOO_PERM_ALL

        acl.id.scheme.should == 'world'
        acl.id.id.should == 'anyone'
      end
    end
  end

  describe :set_acl do

    before do
      @perms = 5
      @new_acl = [ZookeeperACLs::ACL.new(:perms => @perms, :id => ZookeeperACLs::ZOO_ANYONE_ID_UNSAFE)]
      pending("No idea how to set ACLs")
    end

    describe :sync do
      it_should_behave_like "all success return values"

      before do
        @rv = @zk.set_acl(:path => @path, :acl => @new_acl)
      end
      
    end
  end
end
