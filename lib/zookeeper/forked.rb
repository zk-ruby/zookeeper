module Zookeeper
  module Forked
    # the includer provides an 'original_pid' method, which is set
    # when the original 'owning' process creates the object. 
    #
    # @return [true] if the current PID differs from the original_pid value
    # @return [false] if the current PID matches the original_pid value
    #
    def forked?
      Process.pid != original_pid
    end

    # sets the `original_pid` to the current value
    def update_pid!
      self.original_pid = Process.pid
    end
  end # Forked
end # Zookeeper

