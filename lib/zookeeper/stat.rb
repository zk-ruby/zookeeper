module Zookeeper
class Stat
  attr_reader :version, :exists, :czxid, :mzxid, :ctime, :mtime, :cversion, :aversion, :ephemeralOwner, :dataLength, :numChildren, :pzxid

  alias :ephemeral_owner :ephemeralOwner
  alias :num_children :numChildren
  alias :data_length :dataLength

  def initialize(val)
    @exists = !!val
    @czxid, @mzxid, @ctime, @mtime, @version, @cversion, @aversion,
        @ephemeralOwner, @dataLength, @numChildren, @pzxid = val if val.is_a?(Array)
    val.each { |k,v| instance_variable_set "@#{k}", v } if val.is_a?(Hash)
    raise ArgumentError unless (val.is_a?(Hash) or val.is_a?(Array) or val.nil?)
  end

  def exists?
    @exists
  end
end
end
