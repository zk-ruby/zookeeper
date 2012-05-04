module Zookeeper
module Callbacks
  class Base
    attr_reader :proc, :completed, :context

    # allows for easier construction of a user callback block that will be
    # called with the callback object itself as an argument. 
    #
    # @example
    #   
    #   Base.create do |cb|
    #     puts "watcher callback called with argument: #{cb.inspect}"
    #   end
    #
    #   "watcher callback called with argument: #<Zookeeper::Callbacks::Base:0x1018a3958 @state=3, @type=1, ...>"
    #
    #
    def self.create
      cb_inst = new { yield cb_inst }
    end

    def initialize
      @completed = false
      @proc = Proc.new do |hash|
        initialize_context(hash)
        yield if block_given?
        @completed = true
      end
    end
    
    def call(*args)
      @proc.call(*args)
    end
    
    def completed?
      @completed
    end
    
    def initialize_context(hash)
      @context = nil
    end
  end

  class WatcherCallback < Base
    ## wexists, awexists, wget, awget, wget_children, awget_children
    attr_reader :type, :state, :path
    
    def initialize_context(hash)
      @type, @state, @path, @context = hash[:type], hash[:state], hash[:path], hash[:context]
    end
  end

  class DataCallback < Base
    ## aget, awget
    attr_reader :return_code, :data, :stat

    def initialize_context(hash)
      @return_code, @data, @stat, @context = hash[:rc], hash[:data], hash[:stat], hash[:context]
    end
  end

  class StringCallback < Base
    ## acreate, async
    attr_reader :return_code, :string, :context

    alias path string

    def initialize_context(hash)
      @return_code, @string, @context = hash[:rc], hash[:string], hash[:context]
    end
  end

  class StringsCallback < Base
    ## aget_children, awget_children
    attr_reader :return_code, :children, :stat

    def initialize_context(hash)
      @return_code, @children, @stat, @context = hash[:rc], hash[:strings], hash[:stat], hash[:context]
    end
  end

  class StatCallback < Base
    ## aset, aexists, awexists
    attr_reader :return_code, :stat

    def initialize_context(hash)
      @return_code, @stat, @context = hash[:rc], hash[:stat], hash[:context]
    end
  end

  class VoidCallback < Base
    ## adelete, aset_acl, add_auth
    attr_reader :return_code
    
    def initialize_context(hash)
      @return_code, @context = hash[:rc], hash[:context]
    end
  end

  class ACLCallback < Base
    ## aget_acl
    attr_reader :return_code, :acl, :stat
    def initialize_context(hash)
      @return_code, @acl, @stat, @context = hash[:rc], hash[:acl], hash[:stat], hash[:context]
    end
  end
end
end
