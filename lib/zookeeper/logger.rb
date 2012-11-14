module Zookeeper
  module Logger
    def self.wrapped_logger
      if defined?(@@wrapped_logger)
        @@wrapped_logger 
      else
        @@wrapped_logger = ::Logger.new(STDERR).tap { |l| l.level = ::Logger::FATAL }
      end
    end

    def self.wrapped_logger=(log)
      @@wrapped_logger = log
    end

    # @private
    module ClassMethods
      def logger
        ::Zookeeper.logger || ForwardingLogger.for(::Zookeeper::Logger.wrapped_logger, _zk_logger_name)
      end
    end

    def self.included(base)
      # return false if base < self    # avoid infinite recursion
      base.extend(ClassMethods)
    end

    private
      def log_realtime(what)
        logger.debug do
          t = Benchmark.realtime { yield }
          "#{what} took #{t} sec"
        end
      end

      def logger
        @logger ||= (::Zookeeper.logger || self.class.logger)
      end
  end # Logger
end # Zookeeper
