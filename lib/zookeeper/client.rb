# figure out what platform we're on
# this way there's no ambiguity about which file to include
# or which class we're subclassing.

if defined?(::JRUBY_VERSION)
  require_relative('../../java/java_base')
else
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

