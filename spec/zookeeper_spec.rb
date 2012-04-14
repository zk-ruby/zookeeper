require 'spec_helper'
require 'shared/connection_examples'


describe 'Zookeeper' do
  let(:path) { "/_zktest_" }
  let(:data) { "underpants" } 
  let(:zk_host) { 'localhost:2181' }

  let(:zk) do
    Zookeeper.logger.debug { "creating root instance" }
    Zookeeper.new(zk_host)
  end

  it_should_behave_like "connection"
end

