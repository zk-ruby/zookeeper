# @private
module ::Kernel
  unless method_defined?(:silence_warnings)
    def silence_warnings
      with_warnings(nil) { yield }
    end
  end

  unless method_defined?(:with_warnings)
    def with_warnings(flag)
      old_verbose, $VERBOSE = $VERBOSE, flag
      yield
    ensure
      $VERBOSE = old_verbose
    end
  end
end

# @private
class ::Exception
  unless method_defined?(:to_std_format)
    def to_std_format
      ary = ["#{self.class}: #{message}"]
      ary.concat(backtrace || [])
      ary.join("\n\t")
    end
  end
end


