module Zookeeper
  module Logger
    def self.included(mod)
      mod.extend(self)
    end

    def self.const_missing(sym)
      return ::Logger.const_get(sym) if ::Logger.const_defined?(sym)
      super
    end

    def self.new(*a, &b)
      ::Logger.new(*a, &b)
    end

    private
      def log_realtime(what)
        logger.debug do
          t = Benchmark.realtime { yield }
          "#{what} took #{t} sec"
        end
      end

      def logger
        ::Zookeeper.logger
      end
  end
end

