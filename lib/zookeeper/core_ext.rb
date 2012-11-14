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

# this is borrowed from the excellent Logging gem: https://github.com/TwP/logging
# @private
class ::Module
  # @private
  # Returns a predictable logger name for the current module or class. If
  # used within an anonymous class, the first non-anonymous class name will
  # be used as the logger name. If used within a meta-class, the name of the
  # actual class will be used as the logger name. If used within an
  # anonymous module, the string 'anonymous' will be returned.
  def _zk_logger_name
    return name unless name.nil? or name.empty?

    # check if this is a metaclass (or eigenclass)
    if ancestors.include? Class
      inspect =~ %r/#<Class:([^#>]+)>/
      return $1
    end

    # see if we have a superclass
    if respond_to? :superclass
      return superclass.logger_name
    end

    # we are an anonymous module
    return 'anonymous'
  end
end


