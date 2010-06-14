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

def watcher(args)
  puts "#{args.inspect}"
  puts "In watcher: path=#{args.path}, context=#{args.context}"
  if args.path == args.context
    puts "TEST PASSED IN WATCHER"
  else
    puts "TEST FAILED IN WATCHER"
  end
end

wcb = Zookeeper::WatcherCallback.new do
  watcher(wcb)
end

resp = zk.create(:path => '/test', :sequence => true)
puts "#{resp.inspect}"
puts "TEST FAILED [create]" unless resp[:rc] == Zookeeper::ZOK
 
base_path = resp[:path]
watched_file = "#{base_path}/file.does.not.exist"

resp = zk.stat(:path => watched_file, :watcher => wcb, :watcher_context => watched_file)
puts "#{resp.inspect}"
puts "TEST FAILED [stat]" unless resp[:rc] == Zookeeper::ZNONODE

resp = zk.create(:path => watched_file, :data => 'test data', :ephemeral => true)
puts "#{resp.inspect}"
puts "TEST FAILED [create]" unless resp[:rc] == Zookeeper::ZOK

wait_until { wcb.completed? }

puts "TEST FAILED" unless wcb.completed?
puts "TEST PASSED"

zk.delete(:path => watched_file)
zk.delete(:path => base_path)
