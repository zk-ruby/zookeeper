module Zookeeper
  module Logger
    # h/t _eric and Papertrail
    # @private
    class ForwardingLogger
      attr_accessor :level, :formatter

      @@mutex = Monitor.new unless defined?(@@mutex)
      @@loggers = {} unless defined?(@@loggers)

      def self.for(logger, name)
        @@mutex.synchronize do
          @@loggers.fetch(name) do |k|
            @@loggers[k] = new(logger, :formatter => lambda { |m| "%25.25s: %s" % [k, m] })
          end
        end
      end

      def initialize(logger, options = {})
        @level     = ::Logger::DEBUG
        @logger    = logger
        @formatter = options[:formatter]
      end

      def add(severity, message = nil, progname = nil, &block)
        severity ||= ::Logger::UNKNOWN
        if !@logger || severity < @level
          return true
        end
        
        message = (message || (block && block.call) || progname).to_s
        
        if @formatter && @formatter.respond_to?(:call)
          message = @formatter.call(message)
        end

        # If a newline is necessary then create a new message ending with a newline.
        # Ensures that the original message is not mutated.
        # message = "#{message}\n" unless message[-1] == ?\n
        
        @logger.add(severity, message)
      end

      def <<(msg); @logger << msg; end
      def write(msg); @logger.write(msg); end
      
      def debug(progname = nil, &block)
        add(::Logger::DEBUG, nil, progname, &block)
      end
      
      def info(progname = nil, &block)
        add(::Logger::INFO, nil, progname, &block)
      end
      
      def warn(progname = nil, &block)
        add(::Logger::WARN, nil, progname, &block)
      end
      
      def error(progname = nil, &block)
        add(::Logger::ERROR, nil, progname, &block)
      end

      def fatal(progname = nil, &block)
        add(::Logger::FATAL, nil, progname, &block)
      end

      def unknown(progname = nil, &block)
        add(::Logger::UNKNOWN, nil, progname, &block)
      end
      
      def debug?; @level <= DEBUG; end

      def info?; @level <= INFO; end

      def warn?; @level <= WARN; end

      def error?; @level <= ERROR; end

      def fatal?; @level <= FATAL; end
    end # ForwardingLogger
  end # Logger
end # Zookeeper


