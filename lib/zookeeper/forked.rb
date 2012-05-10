module Zookeeper
  module Forked
    @after_hooks = [] unless @after_hooks

    class Subscription
      def initialize(block)
        @block = block
      end

      def unregister
        Forked.unregister(@block)
      end

      def call
        @block.call
      end
    end

    class << self
      attr_reader :after_hooks

      def reopen_after_fork!
        @after_hooks.each(&:call)
      end

      # called when a block should be removed from the hooks
      def unregister(block)
        @after_hooks.delete(block)
      end

      # used by tests
      def clear!
        @after_hooks.clear
      end
    end
    
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
  
  # called in the *child* process after a fork
  # returns a Subscription that may be used to unregister a hook
  def self.after_fork_in_child(callable=nil, &blk)
    callable ||= blk

    unless callable.respond_to?(:call)
      raise ArgumentError, "You must provide either a callable an argument or a block"
    end

    Forked::Subscription.new(callable).tap do |sub|
      Forked.after_hooks << sub
    end
  end
end # Zookeeper

module ::Kernel
  def fork_with_zookeeper_hooks(&block)
    parent_pid = Process.pid

    if block
      new_block = proc do
        Zookeeper::Forked.reopen_after_fork!
        block.call
      end

      fork_without_zookeeper_hooks(&new_block)
    else
      if pid = fork_without_zookeeper_hooks
        # we're in the parent
        return pid
      else
        # we're in the child
        Zookeeper::Forked.reopen_after_fork!
        return nil
      end
    end
  end

  # prevent infinite recursion if we get reloaded
  unless method_defined?(:fork_without_zookeeper_hooks)
    alias_method :fork_without_zookeeper_hooks, :fork
    alias_method :fork, :fork_with_zookeeper_hooks
  end
end

