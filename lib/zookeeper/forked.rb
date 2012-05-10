module Zookeeper
  module Forked
    @hooks = {
      :prepare      => [],
      :after_child  => [],
      :after_parent => [] 
    } unless @hooks

    class Subscription
      def initialize(hook_type, block)
        @hook_type = hook_type
        @block = block
      end

      def unregister
        Forked.unregister(@hook_type, @block)
      end
      alias unsubscribe unregister

      def call
        @block.call
      end
    end

    class << self
      attr_reader :hooks

      def fire_prepare_hooks!
        @hooks[:prepare].each(&:call)
      end

      def fire_after_child_hooks!
        @hooks[:after_child].each(&:call)
      end

      def fire_after_parent_hooks!
        @hooks[:after_parent].each(&:call)
      end

      # called when a block should be removed from the hooks
      def unregister(hook_type, block)
        @hooks.fetch(hook_type).delete(block)
      end

      # used by tests
      def clear!
        @hooks.values(&:clear)
      end

      def register(hook_type, block)
        unless hooks.has_key?(hook_type)
          raise "Invalid hook type specified: #{hook.inspect}" 
        end

        unless block.respond_to?(:call)
          raise ArgumentError, "You must provide either a callable an argument or a block"
        end

        Subscription.new(hook_type, block).tap do |sub|
          @hooks[hook_type] << sub
        end
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

  class << self
    def prepare_for_fork(callable=nil, &blk)
      Forked.register(:prepare, callable||blk)
    end

    def after_fork_in_parent(callable=nil, &blk)
      Forked.register(:after_parent, callable||blk)
    end
    
    # called in the *child* process after a fork
    # returns a Subscription that may be used to unregister a hook
    def after_fork_in_child(callable=nil, &blk)
      Forked.register(:after_child, callable||blk)
    end
  end
end # Zookeeper

module ::Kernel
  def fork_with_zookeeper_hooks(&block)
    parent_pid = Process.pid

    if block
      new_block = proc do
        ::Zookeeper::Forked.fire_after_child_hooks!
        block.call
      end

      ::Zookeeper::Forked.fire_prepare_hooks!
      fork_without_zookeeper_hooks(&new_block).tap do
        ::Zookeeper::Forked.fire_after_parent_hooks!
      end
    else
      ::Zookeeper::Forked.fire_prepare_hooks!
      if pid = fork_without_zookeeper_hooks
        ::Zookeeper::Forked.fire_after_parent_hooks!
        # we're in the parent
        return pid
      else
        # we're in the child
        ::Zookeeper::Forked.fire_after_child_hooks!
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

