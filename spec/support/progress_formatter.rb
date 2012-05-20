require 'rspec/core/formatters/progress_formatter'

module RSpec
  module Core
    module Formatters
      class ProgressFormatter
        def example_started(example)
          ::Logging.logger['spec'].write(yellow("\n=====<([ #{example.full_description} ])>=====\n"))
          super(example)
        end
      end
    end
  end
end

