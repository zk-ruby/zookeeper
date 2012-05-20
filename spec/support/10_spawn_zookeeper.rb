module Zookeeper
  def self.spawn_zookeeper?
    !!ENV['SPAWN_ZOOKEEPER']
  end

  def self.travis?
    !!ENV['TRAVIS']
  end

  @test_port ||= spawn_zookeeper? ? 21811 : 2181

  class << self
    attr_accessor :test_port
  end

  def self.default_cnx_str
    "localhost:#{test_port}"
  end
end

