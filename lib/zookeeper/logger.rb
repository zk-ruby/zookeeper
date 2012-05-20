module Zookeeper
  module Logger
    def self.included(mod)
      return false if mod < self    # avoid infinite recursion
      mod.class_eval do 
        def self.logger
          ::Zookeeper.logger || ::Logging.logger[logger_name]
        end
      end
      mod.extend(self)
    end

    def self.set_default
      ::Logging.logger['Zookeeper'].tap do |ch_root|
        ::Logging.appenders.stderr.tap do |serr|
          serr.layout = ::Logging.layouts.pattern(
            :pattern => '%.1l, [%d] %c30.30{2}:  %m\n',
            :date_pattern => '%Y-%m-%d %H:%M:%S.%6N' 
          )

          ch_root.add_appenders(serr)
        end

        ch_root.level = ENV['ZOOKEEPER_DEBUG'] ? :debug : :off
      end
    end

    private
      def log_realtime(what)
        logger.debug do
          t = Benchmark.realtime { yield }
          "#{what} took #{t} sec"
        end
      end

      def logger
        @logger ||= (::Zookeeper.logger || ::Logging.logger[self.class.logger_name]) # logger_name defined in ::Logging::Utils
      end
  end
end

