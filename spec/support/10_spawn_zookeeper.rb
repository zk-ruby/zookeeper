module Zookeeper
  def self.spawn_zookeeper?
    !!ENV['SPAWN_ZOOKEEPER']
  end

  def self.travis?
    !!ENV['TRAVIS']
  end

  def self.default_cnx_host
    ENV['ZK_DEFAULT_HOST'] || 'localhost'
  end

  @test_port ||= spawn_zookeeper? ? 21811 : 2181

  class << self
    attr_accessor :test_port
  end

  def self.default_cnx_str
    "#{default_cnx_host}:#{test_port}"
  end
end

