module Zookeeper
module Constants
  include ACLs::Constants

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

  # only used by the C extension
  ZOO_LOG_LEVEL_ERROR = 1
  ZOO_LOG_LEVEL_WARN  = 2
  ZOO_LOG_LEVEL_INFO  = 3
  ZOO_LOG_LEVEL_DEBUG = 4

  # exceptions/errors
  ZOK                    =  0
  ZSYSTEMERROR           = -1
  ZRUNTIMEINCONSISTENCY  = -2
  ZDATAINCONSISTENCY     = -3
  ZCONNECTIONLOSS        = -4
  ZMARSHALLINGERROR      = -5
  ZUNIMPLEMENTED         = -6
  ZOPERATIONTIMEOUT      = -7
  ZBADARGUMENTS          = -8
  ZINVALIDSTATE          = -9
  
  # api errors
  ZAPIERROR                 = -100
  ZNONODE                   = -101
  ZNOAUTH                   = -102
  ZBADVERSION               = -103
  ZNOCHILDRENFOREPHEMERALS  = -108
  ZNODEEXISTS               = -110
  ZNOTEMPTY                 = -111
  ZSESSIONEXPIRED           = -112
  ZINVALIDCALLBACK          = -113
  ZINVALIDACL               = -114
  ZAUTHFAILED               = -115
  ZCLOSING                  = -116
  ZNOTHING                  = -117
  ZSESSIONMOVED             = -118

  ZKRB_GLOBAL_CB_REQ = -1
  ZKRB_ASYNC_CONTN_ID = -2

  # @private
  CONNECTED_EVENT_VALUES = [Constants::ZKRB_GLOBAL_CB_REQ, 
                            Constants::ZOO_SESSION_EVENT, 
                            Constants::ZOO_CONNECTED_STATE].freeze

  # used to find the name for a numeric event
  # @private
  EVENT_TYPE_NAMES = {
    1   => 'created',
    2   => 'deleted',
    3   => 'changed',
    4   => 'child',
    -1  => 'session',
    -2  => 'notwatching',
  }

  # used to pretty print the state name
  # @private
  STATE_NAMES = {
    -112 => 'expired_session',
    -113 => 'auth_failed',
    0    => 'closed',
    1    => 'connecting',
    2    => 'associating',
    3    => 'connected',
  }
              
  def event_by_value(v)
    (name = EVENT_TYPE_NAMES[v]) ?  "ZOO_#{name.upcase}_EVENT" : ''
  end

  def state_by_value(v)
    (name = STATE_NAMES[v]) ?  "ZOO_#{name.upcase}_STATE" : ''
  end
end
end
