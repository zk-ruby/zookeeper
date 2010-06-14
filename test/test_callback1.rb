require 'rubygems'
require 'zookeeper'

def wait_until(timeout=10, &block)
  time_to_stop = Time.now + timeout
  until yield do
    break if Time.now > time_to_stop
    sleep 0.1
  end
end

puts 'Initializing Zookeeper'

zk = Zookeeper.new('localhost:2181')

if zk.state != Zookeeper::ZOO_CONNECTED_STATE
  puts 'Unable to connect to Zookeeper!'
  Kernel.exit
end

def callback(args)
  puts "CALLBACK EXECUTED, args = #{args.inspect}"
  puts args.return_code == Zookeeper::ZOK ? "TEST PASSED IN CALLBACK" : "TEST FAILED IN CALLBACK"
end

ccb = Zookeeper::VoidCallback.new do
  callback(ccb)
end

resp = zk.create(:path => '/test', :data => "new data", :sequence => true, :callback => ccb)
puts "#{resp.inspect}"
puts "TEST FAILED [create]" unless resp[:rc] == Zookeeper::ZOK
 
wait_until { ccb.completed? }

puts ccb.completed? ? "TEST PASSED" : "TEST FAILED"
