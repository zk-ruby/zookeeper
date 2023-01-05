require 'spec_helper'

unless defined?(::JRUBY_VERSION)
  describe Zookeeper::ZookeeperBase do
    before do
      @zk = described_class.new(Zookeeper.default_cnx_str)
    end

    after do
      @zk.close unless @zk.closed?
    end

    it %[should have an original_pid assigned] do
      expect(@zk.original_pid).to eq(Process.pid)
    end
  end
end


