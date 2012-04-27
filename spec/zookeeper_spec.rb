require 'spec_helper'
require 'shared/connection_examples'


describe 'Zookeeper' do
  let(:path) { "/_zktest_" }
  let(:data) { "underpants" } 
  let(:connection_string) { 'localhost:2181' }

  before do
    @zk = Zookeeper.new(connection_string)
  end

  after do
    @zk and @zk.close
  end

  def zk
    @zk
  end

  it_should_behave_like "connection"
end

