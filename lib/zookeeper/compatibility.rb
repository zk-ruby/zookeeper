module Zookeeper
  # @private
  def self.warn_about_compatability_once!
    return if @warned_about_compatibility
    @warned_about_compatibility = true

    warn <<-EOS

-----------------------------------------------------------------------------

          NOTICE: ZOOKEEPER BACKWARDS COMPATIBILTY EANBLED!! 
        
               THIS WILL NOT BE AUTOMATIC IN 1.1 !!

  There was a major change to the organization of the Zookeeper gem between
  0.9 and 1.0, breaking backwards compatibility. To ease the transition, 
  
  #{__FILE__}
  
  is automatically required. This will *not* be the case in 1.1.

-----------------------------------------------------------------------------
    EOS
  end

  def self.warned_about_compatability?
    !!@warned_about_compatability
  end
end

# at request of @eric
#Zookeeper.warn_about_compatability_once!

module Zookeeper
  module Compatibility
    def clean_backtrace
      caller[0..-2].reject {|n| n =~ %r%/rspec/|\(eval\)|const_missing% }.map { |n| "\t#{n}" }.join("\n")
    end
  end
end

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
  extend Zookeeper::Compatibility
  def self.const_missing(sym)
    if sym == :Stat
      warn "\nZookeeperStat::Stat is now Zookeeper::Stat, please update your code!\n#{clean_backtrace}"
#       self.const_set(sym, Zookeeper::Stat)
      Zookeeper::Stat
    else
      super
    end
  end
end

module ZookeeperACLs
  extend Zookeeper::Compatibility
  def self.const_missing(sym)
    candidates = [Zookeeper::ACLs, Zookeeper::Constants, Zookeeper::ACLs::Constants]

    candidates.each do |candidate|
      if candidate.const_defined?(sym)
        warn "\n#{self.name}::#{sym} is now located in #{candidate}::#{sym}, please update your code!\n#{clean_backtrace}"

        c = candidate.const_get(sym)
#         self.const_set(sym, c)
        return c
      end
    end

    super
  end
end

module ZookeeperCommon
  include Zookeeper::Common
  extend Zookeeper::Compatibility
  
  def self.const_missing(sym)
    candidate = Zookeeper::Common

    if candidate.const_defined?(sym)
      warn "\n#{self.name}::#{sym} is now located in #{candidate}::#{sym}, please update your code!\n#{clean_backtrace}"

      candidate.const_get(sym).tap do |c|
#         self.const_set(sym, c)
      end
    else
      super
    end
  end

end

# module Zookeeper
#   include ZookeeperConstants
#   include ZookeeperCallbacks
#   include ZookeeperExceptions
#   include ZookeeperCommon
#   include ZookeeperStat
#   include ZookeeperACLs
# end

module Zookeeper
  extend Zookeeper::Compatibility
  def self.const_missing(sym)
    candidate =
      case sym.to_s
      when /Callback/
        Zookeeper::Callbacks
      end

    super unless candidate

    if candidate.const_defined?(sym)
      warn "\n#{self.name}::#{sym} is now located in #{candidate}::#{sym}, please update your code!\n#{clean_backtrace}"

      candidate.const_get(sym).tap do |c|
#         self.const_set(sym, c)
      end
    else
      super
    end
  end
end

