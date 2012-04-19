require 'spec_helper'
require 'shared/connection_examples'

describe 'Zookeeper chrooted' do
  let(:path) { "/_zkchroottest_" }
  let(:data) { "underpants" } 
  let(:chroot_path) { '/slyphon-zookeeper-chroot' }

  let(:connection_string) { "localhost:2181#{chroot_path}" }

  before do
    @zk = Zookeeper.new(connection_string)
  end

  after do
    @zk and @zk.close
  end


  def zk
    @zk
  end

  def with_open_zk(host='localhost:2181')
    z = Zookeeper.new(host)
    yield z
  ensure
    z.close

    wait_until do 
      begin
        !z.connected?
      rescue RuntimeError
        true
      end
    end
  end

  # this is not as safe as the one in ZK, just to be used to clean up
  # when we're the only one adjusting a particular path
  def rm_rf(z, path)
    z.get_children(:path => path).tap do |h|
      if h[:rc].zero?
        h[:children].each do |child|
          rm_rf(z, File.join(path, child))
        end
      elsif h[:rc] == ZookeeperExceptions::ZNONODE
        # no-op
      else
        raise "Oh noes! unexpected return value! #{h.inspect}"
      end
    end

    rv = z.delete(:path => path)

    unless (rv[:rc].zero? or rv[:rc] == ZookeeperExceptions::ZNONODE)
      raise "oh noes! failed to delete #{path}" 
    end

    path
  end

  describe 'non-existent' do
    describe 'with existing parent' do
      let(:chroot_path) { '/one-level' }

      describe 'create' do
        before do
          with_open_zk do |z|
            rm_rf(z, chroot_path)
          end
        end

        it %[should successfully create the path] do
          rv = zk.create(:path => '/', :data => '')
          rv[:rc].should be_zero
          rv[:path].should == ''
        end
      end
    end

    describe 'with missing parent' do
      let(:chroot_path) { '/deeply/nested/path' }

      describe 'create' do
        before do
          with_open_zk do |z|
            rm_rf(z, chroot_path)
          end
        end

        it %[should return ZNONODE] do
          rv = zk.create(:path => '/', :data => '')
          rv[:rc].should_not be_zero
          rv[:rc].should == ZookeeperExceptions::ZNONODE
        end
      end
    end
  end


  describe do
    before :all do
      Zookeeper.logger.warn "running before :all"

      with_open_zk do |z|
        z.create(:path => chroot_path, :data => '')
      end
    end

    after :all do
      with_open_zk do |z|
        rm_rf(z, chroot_path)
      end
    end

    it_should_behave_like "connection"
  end
end


