require 'rubygems'
require 'zookeeper'
z = Zookeeper.new("localhost:2181")
path = "/testing_node"
z.get(:path => path)
z.create(:path => path, :data => "initial value", :ephemeral => true)
z.get(:path => path)
z.close()
sleep 5
begin
  z.get(:path => path)
rescue Exception => e
  puts "Rescued exception #{e.inspect}"
end
z.reopen
z.get(:path => path)
