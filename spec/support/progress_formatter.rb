require 'rspec/core/formatters/progress_formatter'

module RSpec
  module Core
    module Formatters
      class ProgressFormatter
        def example_started(example)
          Zookeeper.logger.info(yellow("=====<([ #{example.full_description} ])>====="))
          super(example)
        end
      end
    end
  end
end

