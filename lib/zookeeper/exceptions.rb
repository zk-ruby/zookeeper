module Zookeeper
module Exceptions
  include Constants

  class ZookeeperException < StandardError

    unless defined?(CONST_MISSING_WARNING)

      CONST_MISSING_WARNING = <<-EOS

------------------------------------------------------------------------------------------
WARNING! THE ZOOKEEPER NAMESPACE HAS CHANGED AS OF 1.0!

Please update your code to use the new hierarchy!

The constant that got you this was ZookeeperExceptions::ZookeeperException::%s

stacktrace: 
%s

------------------------------------------------------------------------------------------

      EOS
    end

    # NOTE(slyphon): Since 0.4 all of the ZookeeperException subclasses were
    #   defined inside of ZookeeperException, which always seemed well, icky.
    #   if someone references one of these we'll print out a warning and 
    #   then give them the constant
    # 
    def self.const_missing(const)
      if Zookeeper::Exceptions.const_defined?(const)

        stacktrace = caller[0..-2].reject {|n| n =~ %r%/rspec/% }.map { |n| "\t#{n}" }.join("\n")

        Zookeeper.deprecation_warning(CONST_MISSING_WARNING % [const.to_s, stacktrace])


        Zookeeper::Exceptions.const_get(const).tap do |const_val|
          self.const_set(const, const_val)
        end
      else
        super
      end
    end
  end


  class EverythingOk            < ZookeeperException; end
  class SystemError             < ZookeeperException; end
  class RunTimeInconsistency    < ZookeeperException; end
  class DataInconsistency       < ZookeeperException; end
  class ConnectionLoss          < ZookeeperException; end
  class MarshallingError        < ZookeeperException; end
  class Unimplemented           < ZookeeperException; end
  class OperationTimeOut        < ZookeeperException; end
  class BadArguments            < ZookeeperException; end
  class InvalidState            < ZookeeperException; end
  class ApiError                < ZookeeperException; end
  class NoNode                  < ZookeeperException; end
  class NoAuth                  < ZookeeperException; end
  class BadVersion              < ZookeeperException; end
  class NoChildrenForEphemerals < ZookeeperException; end
  class NodeExists              < ZookeeperException; end
  class NotEmpty                < ZookeeperException; end
  class SessionExpired          < ZookeeperException; end
  class InvalidCallback         < ZookeeperException; end
  class InvalidACL              < ZookeeperException; end
  class AuthFailed              < ZookeeperException; end
  class Closing                 < ZookeeperException; end
  class Nothing                 < ZookeeperException; end
  class SessionMoved            < ZookeeperException; end
  
  # these are Ruby client exceptions
  class ConnectionClosed        < ZookeeperException; end
  class NotConnected            < ZookeeperException; end 
  class ShuttingDownException   < ZookeeperException; end
  class DataTooLargeException   < ZookeeperException; end

  # raised when an operation is performed on an instance without a valid
  # zookeeper handle. (C version)
  class HandleClosedException < ZookeeperException; end

  # maybe use this for continuation
  class InterruptedException  < ZookeeperException ; end

  # raised when a continuation operation takes more time than is reasonable and
  # the thread should be awoken. (i.e. prevents a call that never returns)
  class ContinuationTimeoutError < ZookeeperException; end

  # raised when the user tries to use a connection after a fork()
  # without calling reopen() in the C client
  #
  # (h/t: @pletern http://git.io/zIsq1Q)
  class InheritedConnectionError < ZookeeperException; end

  # yes, make an alias, this is the way zookeeper refers to it
  ExpiredSession = SessionExpired unless defined?(ExpiredSession)
    
  def self.by_code(code)
    case code
      when ZOK then EverythingOk
      when ZSYSTEMERROR then SystemError
      when ZRUNTIMEINCONSISTENCY then RunTimeInconsistency
      when ZDATAINCONSISTENCY then DataInconsistency
      when ZCONNECTIONLOSS then ConnectionLoss
      when ZMARSHALLINGERROR then MarshallingError
      when ZUNIMPLEMENTED then Unimplemented
      when ZOPERATIONTIMEOUT then OperationTimeOut
      when ZBADARGUMENTS then BadArguments
      when ZINVALIDSTATE then InvalidState
      when ZAPIERROR then ApiError
      when ZNONODE then NoNode
      when ZNOAUTH then NoAuth
      when ZBADVERSION then BadVersion
      when ZNOCHILDRENFOREPHEMERALS then NoChildrenForEphemerals 
      when ZNODEEXISTS then NodeExists              
      when ZNOTEMPTY then NotEmpty                
      when ZSESSIONEXPIRED then SessionExpired          
      when ZINVALIDCALLBACK then InvalidCallback         
      when ZINVALIDACL then InvalidACL
      when ZAUTHFAILED then AuthFailed
      when ZCLOSING then Closing
      when ZNOTHING then Nothing
      when ZSESSIONMOVED then SessionMoved
    else ZookeeperException.new("no exception defined for code #{code}")
    end
  end
  
  def self.raise_on_error(code)
    exc = self.by_code(code)
    raise exc unless exc == EverythingOk
  end
end # Exceptions
end # Zookeeper
