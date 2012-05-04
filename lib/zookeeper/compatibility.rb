module ZookeeperConstants
  include Zookeeper::Constants
end

module ZookeeperCallbacks
  include Zookeeper::Callbacks
  Callback = Base
end

module ZookeeperExceptions
  include Zookeeper::Exceptions
end

module ZookeeperStat
  Stat = ::Zookeeper::Stat
end

module ZookeeperACLs
  include Zookeeper::ACLs
  include Zookeeper::ACLs::Constants
end

module ZookeeperCommon
  include Zookeeper::Common
end

module Zookeeper
  include ZookeeperConstants
  include ZookeeperCallbacks
  include ZookeeperExceptions
  include ZookeeperCommon
  include ZookeeperStat
  include ZookeeperACLs
end

