require 'rubygems'
require 'zookeeper'

z = Zookeeper.new("localhost:2181")

puts "root: #{z.get_children(:path => "/").inspect}"

path = "/testing_node"

puts "working with path #{path}"

h = z.stat(:path => path)
stat = h[:stat]
puts "exists? #{stat.inspect}"

if stat.exists
  z.get_children(:path => path)[:children].each do |o|
    puts "  child object: #{o}"
  end
  puts "delete: #{z.delete(:path => path, :version => stat.version).inspect}"
end

puts "create: #{z.create(:path => path, :data => 'initial value').inspect}"

v = z.get(:path => path)
value, stat = v[:data], v[:stat]
puts "current value #{value}, stat #{stat.inspect}"

puts "set: #{z.set(:path => path, :data => 'this is a test', :version => stat.version).inspect}"

v = z.get(:path => path)
value, stat = v[:data], v[:stat]
puts "new value: #{value.inspect} #{stat.inspect}"

puts "delete: #{z.delete(:path => path, :version => stat.version).inspect}"

puts "exists? #{z.stat(:path => path)[:stat].exists}"
