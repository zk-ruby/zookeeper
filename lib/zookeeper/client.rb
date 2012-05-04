# figure out what platform we're on

if defined?(::JRUBY_VERSION)
#   $stderr.puts "Loading the jruby extensions"
#   $LOAD_PATH.unshift(File.expand_path('../../../java', __FILE__)).uniq!
#   require 'java_base'
  
  require_relative('../../java/java_base')
else
#   $stderr.puts "adding the C extensions"
#   $LOAD_PATH.unshift(File.expand_path('../../../ext', __FILE__)).uniq!
#   require 'zookeeper_base'

  require_relative('../../ext/zookeeper_base')
end


module Zookeeper
  if defined?(::JRUBY_VERSION)
    class Client < Zookeeper::JavaBase
    end
  else
    class Client < Zookeeper::ZookeeperBase
    end
  end

  def self.new(*a, &b)
    Zookeeper::Client.new(*a, &b)
  end
end


Zookeeper::Client.class_eval do
  include Zookeeper::ClientMethods
end

