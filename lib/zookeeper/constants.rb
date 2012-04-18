module ZookeeperConstants
  # file type masks
  ZOO_EPHEMERAL = 1
  ZOO_SEQUENCE  = 2
  
  # session state
  ZOO_EXPIRED_SESSION_STATE  = -112
  ZOO_AUTH_FAILED_STATE      = -113
  ZOO_CLOSED_STATE           = 0
  ZOO_CONNECTING_STATE       = 1
  ZOO_ASSOCIATING_STATE      = 2
  ZOO_CONNECTED_STATE        = 3
  
  # watch types
  ZOO_CREATED_EVENT      = 1
  ZOO_DELETED_EVENT      = 2
  ZOO_CHANGED_EVENT      = 3
  ZOO_CHILD_EVENT        = 4
  ZOO_SESSION_EVENT      = -1
  ZOO_NOTWATCHING_EVENT  = -2

  # used to find the name for a numeric event
  # @private
  EVENT_TYPE_NAMES = {
    1   => :created,
    2   => :deleted,
    3   => :changed,
    4   => :child,
    -1  => :session,
    -2  => :notwatching,
  }

  # used to pretty print the state name
  # @private
  STATE_NAMES = {
    -112 => :expired_session,
    -113 => :auth_failed,
    0    => :closed,
    1    => :connecting,
    2    => :associating,
    3    => :connected,
  }
              
  def print_events
    puts "ZK events:"
    ZookeeperConstants::constants.each do |c|
      puts "\t #{c}" if c =~ /^ZOO..*EVENT$/
    end
  end

  def print_states
    puts "ZK states:"
    ZookeeperConstants::constants.each do |c|
      puts "\t #{c}" if c =~ /^ZOO..*STATE$/
    end
  end

  def event_by_value(v)
    return unless v
    ZookeeperConstants::constants.each do |c|
      next unless c =~ /^ZOO..*EVENT$/
      if eval("ZookeeperConstants::#{c}") == v
        return c
      end
    end
  end
  
  def state_by_value(v)
    return unless v
    ZookeeperConstants::constants.each do |c|
      next unless c =~ /^ZOO..*STATE$/
      if eval("ZookeeperConstants::#{c}") == v
        return c
      end
    end
  end
end
