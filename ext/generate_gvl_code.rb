#!/usr/bin/env ruby

=begin
the idea here is to take each zoo_* function declaration in the header file, and turn it into
a calling arguments struct, a wrapper function and a macro for packing the values.

so for:

  ZOOAPI int zoo_acreate(zhandle_t *zh, const char *path, const char *value, 
          int valuelen, const struct ACL_vector *acl, int flags,
          string_completion_t completion, const void *data);

we want

  typedef struct {
    zhandle_t *zh;
    const char *path;
    const char *value;
    int valuelen;
    const struct ACL_vector *acl;
    int flags;
    string_completion_t completion;
    const void *data;
  } zkrb_zoo_acreate_args_t;

  static VALUE zkrb_gvl_zoo_acreate(void *data) {
    zkrb_zoo_acreate_args_t *a = (zkrb_zoo_acreate_args_t *)data;
  
    a->rc = zoo_acreate(a->zh, a->path, a->value, a->valuelen, a->acl, a->flags, a->completion, a->data);
  
    return Qnil;
  }

  static int zkrb_call_zoo_acreate(zhandle_t *zh, const char *path, const char *value, 
                int valuelen, const struct ACL_vector *acl, int flags,
                string_completion_t completion, const void *data) {

    zkrb_zoo_acreate_args_t args = {
      .rc = ZKRB_FAIL,
      .zh = zh,
      .path = path,
      .value = value,
      .valuelen = valuelen,
      .acl = acl,
      .flags = flags,
      .completion = completion,
      .data = data
    };

    zkrb_thread_blocking_region(zkrb_gvl_zoo_acreate, (void *)&args);

    return args.rc;
  }

=end

REGEXP = /^ZOOAPI int (zoo_[^(]+)\(([^)]+)\);$/m

require 'forwardable'
require 'stringio'

THIS_DIR = File.expand_path('..', __FILE__)

ZKRB_WRAPPER_H_PATH = File.expand_path('../zkrb_wrapper.h', __FILE__)
ZKRB_WRAPPER_C_PATH = File.expand_path('../zkrb_wrapper.c', __FILE__)

# the struct that holds the call args for zoo_fn_name
class CallStruct
  attr_reader :zoo_fn_name, :typed_args, :name

  def initialize(zoo_fn_name, typed_args)
    @zoo_fn_name, @typed_args = zoo_fn_name, typed_args
    @name = "zkrb_#{zoo_fn_name}_args_t"
  end

  def body
    @body ||= (
      lines = ["typedef struct {"]
      lines += typed_args.map{|n| "  #{n};"}
      lines << "  int rc;"
      lines << "} #{name};"
      lines.join("\n")
    )
  end
end

module MemberNames
  def member_names
    @member_names ||= typed_args.map { |n| n.split(/[ *]/).last }
  end
end

# the zkrb_gvl_zoo_* function
class WrapperFunction
  extend Forwardable
  include MemberNames

  PREFIX = 'zkrb_gvl'

  def_delegators :struct, :typed_args

  attr_reader :struct, :name, :zoo_fn_name

  def initialize(zoo_fn_name, struct)
    @zoo_fn_name = zoo_fn_name
    @struct = struct
    @name = "#{PREFIX}_#{zoo_fn_name}"
  end

  def fn_signature
    @fn_signature ||= "static VALUE #{name}(void *data)"
  end

  def body
    @body ||= (
      lines = ["#{fn_signature} {"]
      lines << "  #{struct.name} *a = (#{struct.name} *)data;"

      funcall = "  a->rc = #{zoo_fn_name}("
      funcall << member_names.map { |m| "a->#{m}" }.join(', ')
      funcall << ');'

      lines << funcall

      lines << "  return Qnil;"
      lines << "}"
      lines.join("\n")
    )
  end
end

# the zkrb_call_zoo_* function
class CallingFunction
  extend Forwardable
  include MemberNames
  
  PREFIX = 'zkrb_call'

  def_delegators :struct, :typed_args

  attr_reader :struct, :wrapper_fn, :zoo_fn_name, :name

  def initialize(zoo_fn_name, struct, wrapper_fn)
    @zoo_fn_name, @struct, @wrapper_fn = zoo_fn_name, struct, wrapper_fn

    @name = "#{PREFIX}_#{zoo_fn_name}"
  end

  def fn_signature
    @fn_signature ||= "int #{name}(#{typed_args.join(', ')})"
  end

  def initializer_lines
    @initializer_lines ||= member_names.map { |n| "    .#{n} = #{n}" }.join(",\n")
  end

  def top
    <<-EOS
// wrapper that calls #{zoo_fn_name} via #{wrapper_fn.name} inside rb_thread_blocking_region
#{fn_signature} {
  #{struct.name} args = {
    .rc = ZKRB_FAIL,
#{initializer_lines}
  };
    EOS
  end

  def rb_thread_blocking_region_call
    "  zkrb_thread_blocking_region(#{wrapper_fn.name}, (void *)&args);"
  end

  def bottom
    <<-EOS

  return args.rc;
}
    EOS
  end

  def body
    @body ||= [top, rb_thread_blocking_region_call, bottom].join("\n")
  end
end

class GeneratedCode < Struct.new(:structs, :wrapper_fns, :calling_fns)
  def initialize(*a)
    super

    self.structs     ||= []
    self.wrapper_fns ||= []
    self.calling_fns ||= []
  end

  def self.from_zookeeper_h(text)
    new.tap do |code|
      while true
        break unless text =~ REGEXP
        text = $~.post_match

        zoo_fn_name, argstr = $1
        argstr = $2

        typed_args = argstr.split(',').map(&:strip)

        # gah, fix up functions which have a void_completion_t with no name assigned
        if idx = typed_args.index('void_completion_t')
          typed_args[idx] = 'void_completion_t completion'
        end

        struct = CallStruct.new(zoo_fn_name, typed_args)
        wrapper_fn = WrapperFunction.new(zoo_fn_name, struct)
        calling_fn = CallingFunction.new(zoo_fn_name, struct, wrapper_fn)

        code.structs << struct
        code.wrapper_fns << wrapper_fn
        code.calling_fns << calling_fn
      end
    end
  end
end

def render_header_file(code)
  StringIO.new('zkrb_wrapper.h', 'w').tap do |fp|
    fp.puts <<-EOS
#ifndef ZKRB_WRAPPER_H
#define ZKRB_WRAPPER_H
#if 0

  AUTOGENERATED BY #{File.basename(__FILE__)} 

#endif

#include "ruby.h"
#include "zookeeper/zookeeper.h"
#include "zkrb_wrapper_compat.h"
#include "dbg.h"

#define ZKRB_FAIL -1

    EOS

    code.structs.each do |struct|
      fp.puts(struct.body)
      fp.puts
    end

    code.calling_fns.each do |cf|
      fp.puts "#{cf.fn_signature};"
    end

    fp.puts <<-EOS

#endif /* ZKRB_WRAPPER_H */
    EOS

  end.string
end

def render_c_file(code)
  StringIO.new('zkrb_wrapper.c', 'w').tap do |fp|
    fp.puts <<-EOS
/*

Autogenerated boilerplate wrappers around zoo_* function calls necessary for using
rb_thread_blocking_region to release the GIL when calling native code.

generated by ext/#{File.basename(__FILE__)}

*/

#include "ruby.h"
#include "zkrb_wrapper.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

    EOS

    code.wrapper_fns.zip(code.calling_fns) do |wrap_fn, call_fn|
      fp.puts "#{wrap_fn.body}\n\n"
      fp.puts "#{call_fn.body}\n\n"
    end

  end.string
end


def help!
  $stderr.puts "usage: #{File.basename(__FILE__)} {all|headers|code}"
  exit 1
end

def main
  help! if ARGV.empty?
  opts = []

  zookeeper_h_path = Dir[File.join(THIS_DIR, "**/zookeeper.h")].first

  raise "Could not locate zookeeper.h!" unless zookeeper_h_path

  text = File.read(zookeeper_h_path)
  code = GeneratedCode.from_zookeeper_h(text)

  cmd = ARGV.first

  help! unless %w[headers all code].include?(cmd)

  if %w[headers all].include?(cmd)
    $stderr.puts "writing #{ZKRB_WRAPPER_H_PATH}"
    File.open(ZKRB_WRAPPER_H_PATH, 'w') { |fp| fp.write(render_header_file(code)) }
  end

  if %w[code all].include?(cmd)
    $stderr.puts "writing #{ZKRB_WRAPPER_C_PATH}"
    File.open(ZKRB_WRAPPER_C_PATH, 'w') { |fp| fp.write(render_c_file(code)) }
  end

end

main

