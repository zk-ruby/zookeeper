require 'spec_helper'
require 'shared/connection_examples'

describe 'Zookeeper chrooted' do
  let(:path) { "/_zkchroottest_" }
  let(:data) { "underpants" } 
  let(:chroot_path) { '/slyphon-zookeeper-chroot' }

  let(:connection_string) { "#{Zookeeper.default_cnx_str}#{chroot_path}" }

  before do
    @zk = Zookeeper.new(connection_string)
  end

  after do
    @zk and @zk.close
  end

  def zk
    @zk
  end

  describe 'non-existent' do
    describe 'with existing parent' do
      let(:chroot_path) { '/one-level' }

      describe 'create' do
        before do
          with_open_zk { |z| rm_rf(z, chroot_path) }
        end

        after do
          with_open_zk { |z| rm_rf(z, chroot_path) }
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
          rv[:rc].should == Zookeeper::Exceptions::ZNONODE
        end
      end
    end
  end


  describe do
    before :all do
      logger.warn "running before :all"

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


