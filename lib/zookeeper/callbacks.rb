module ZookeeperCallbacks
  class Callback
    attr_reader :proc, :completed, :context

    def initialize
      @completed = false
      @proc = Proc.new do |hash|
        initialize_context(hash)
        yield if block_given?
        @completed = true
      end
    end
    
    def call(*args)
      # puts "call passed #{args.inspect}"
      @proc.call(*args)
    end
    
    def completed?
      @completed
    end
    
    def initialize_context(hash)
      @context = nil
    end
  end
  
  class WatcherCallback < Callback
    ## wexists, awexists, wget, awget, wget_children, awget_children
    attr_reader :type, :state, :path
    
    def initialize_context(hash)
      @type, @state, @path, @context = hash[:type], hash[:state], hash[:path], hash[:context]
    end
  end

  class DataCallback < Callback
    ## aget, awget
    attr_reader :return_code, :data, :stat

    def initialize_context(hash)
      @return_code, @data, @stat, @context = hash[:rc], hash[:data], hash[:stat], hash[:context]
    end
  end

  class StringCallback < Callback
    ## acreate, async
    attr_reader :return_code, :path

    def initialize_context(hash)
      @return_code, @path, @context = hash[:rc], hash[:string], hash[:context]
    end
  end

  class StringsCallback < Callback
    ## aget_children, awget_children
    attr_reader :return_code, :children, :stat

    def initialize_context(hash)
      @return_code, @children, @stat, @context = hash[:rc], hash[:strings], hash[:stat], hash[:context]
    end
  end

  class StatCallback < Callback
    ## aset, aexists, awexists
    attr_reader :return_code, :stat

    def initialize_context(hash)
      @return_code, @stat, @context = hash[:rc], hash[:stat], hash[:context]
    end
  end

  class VoidCallback < Callback
    ## adelete, aset_acl, add_auth
    attr_reader :return_code
    
    def initialize_context(hash)
      @return_code, @context = hash[:rc], hash[:context]
    end
  end

  class ACLCallback < Callback
    ## aget_acl
    attr_reader :return_code, :acl, :stat
    def initialize_context(hash)
      @return_code, @acl, @stat, @context = hash[:rc], hash[:acl], hash[:stat], hash[:context]
    end
  end
end
