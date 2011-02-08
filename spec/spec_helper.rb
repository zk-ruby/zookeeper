$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))
$LOAD_PATH.unshift(File.expand_path('../../ext', __FILE__))
$LOAD_PATH.uniq!

require 'rubygems'

gem 'rspec', '~> 2.4.0'
gem 'flexmock', '~> 0.8.11'

require 'flexmock'
require 'rspec'

Rspec.configure do |config|
  config.mock_with :flexmock

  config.before(:all) do
    @zk = Zookeeper.new('localhost:2181')
  end

  config.after(:all) do
    @zk.close
  end
end


