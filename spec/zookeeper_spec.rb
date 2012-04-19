require 'spec_helper'
require 'shared/connection_examples'


describe 'Zookeeper' do
  let(:path) { "/_zktest_" }
  let(:data) { "underpants" } 
  let(:zk_host) { 'localhost:2181' }

  before do
    @zk = Zookeeper.new(zk_host)
  end

  after do
    @zk and @zk.close
  end

  def zk
    @zk
  end

  it_should_behave_like "connection"
end

