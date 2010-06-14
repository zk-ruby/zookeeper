require 'rubygems'
require 'zookeeper'
zk = Zookeeper.new('localhost:2181')

puts "get acl #{zk.get_acl(:path => '/').inspect}"
puts "zerror #{zk.zerror(Zookeeper::ZBADVERSION)}"

