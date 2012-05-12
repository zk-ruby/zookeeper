module Zookeeper
  # just like stdlib Monitor but provides the SAME API AS MUTEX, FFS!
  class Monitor
    include MonitorMixin

    alias try_enter try_mon_enter
    alias enter mon_enter
    alias exit mon_exit

    # here, HERE!
    # *here* are the methods that are the same
    # god *dammit*

    alias lock mon_enter
    alias unlock mon_exit
    alias try_lock try_mon_enter
  end
end

