require 'logger'

module Zookeeper
  module Logger
    def self.included(mod)
      return false if mod < self    # avoid infinite recursion
      mod.class_eval do 
        def self.logger
          ::Zookeeper.logger || ::Logger.new(STDOUT)
        end
      end
      mod.extend(self)
    end

    private
      def log_realtime(what)
        logger.debug do
          t = Benchmark.realtime { yield }
          "#{what} took #{t} sec"
        end
      end

      def logger
        @logger ||= (::Zookeeper.logger || ::Logger.new(STDOUT))
      end
  end
end

