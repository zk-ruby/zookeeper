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

      int rc;
      zkrb_zoo_acreate_args_t *ptr = malloc(sizeof(zkrb_zoo_acreate_args_t)); 
      check_mem(ptr);

      ptr->rc = 0; 
      ptr->zh = zh; 
      ptr->path = path; 
      ptr->value = value;
      ptr->valuelen = valuelen;
      ptr->acl = acl;
      ptr->flags = flags;
      ptr->completion = completion;
      ptr->data = data; 

      rb_thread_blocking_region(zkrb_gvl_zoo_acreate, (void *)ptr, RUBY_UBF_IO, 0);

      rc = ptr->rc;
      free(ptr);
      return rc;

    error:
      free(ptr); 
      return -1;
  }

=end

REGEXP = /^ZOOAPI int (zoo_[^(]+)\(([^)]+)\);$/m

require 'forwardable'
require 'stringio'

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
    @fn_signature ||= "static int #{name}(#{typed_args.join(', ')})"
  end

  def ptr_lines
    @ptr_lines = (
      lines = ["ptr->rc = rc;"]
      lines += member_names.map { |n| "ptr->#{n} = n;" }
      lines.map! { |n| "  #{n}" }
      lines.join("\n")
    )
  end

  def top
    <<-EOS
// wrapper that calls #{zoo_fn_name} via #{wrapper_fn.name} inside rb_thread_blocking_region
#{fn_signature} {
  int rc = ZKRB_FAIL;
  #{struct.name} *ptr = malloc(sizeof(#{struct.name}));
  check_mem(ptr);
    EOS
  end

  def rb_thread_blocking_region_call
    "  rb_thread_blocking_region(#{wrapper_fn.name}, (void *)ptr, RUBY_UBF_IO, 0);"
  end

  def bottom
    <<-EOS

  rc = ptr->rc;

error:
  free(ptr);
  return rc;
}
    EOS
  end

  def body
    @body ||= [top, ptr_lines, nil, rb_thread_blocking_region_call, bottom].join("\n")
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
        zoo_fn_name, argstr = $1
        argstr = $2

        typed_args = argstr.split(',').map(&:strip)

        struct = CallStruct.new(zoo_fn_name, typed_args)
        wrapper_fn = WrapperFunction.new(zoo_fn_name, struct)
        calling_fn = CallingFunction.new(zoo_fn_name, struct, wrapper_fn)

        code.structs << struct
        code.wrapper_fns << wrapper_fn
        code.calling_fns << calling_fn

        text = $~.post_match
      end
    end
  end
end

def render_header_file(code)
  StringIO.open('zkrb_wrapper.h', 'w') do |fp|
    fp.puts <<-EOS
#ifndef ZKRB_WRAPPER_H
#define ZKRB_WRAPPER_H
#if 0

  AUTOGENERATED BY #{File.basename(__FILE__)} 

#endif

#include "ruby.h"
#include "c-client-src/zookeeper.h"
#include "dbg.h"

#define ZKRB_FAIL -1

    EOS

    code.structs.each do |struct|
      fp.puts(struct.body)
      fp.puts
    end

    code.wrapper_fns.each do |wf|
      fp.puts "#{wf.fn_signature};"
    end

    fp.puts

    code.calling_fns.each do |cf|
      fp.puts "#{cf.fn_signature};"
    end

    fp.puts <<-EOS

#endif /* ZKRB_WRAPPER_H */
    EOS

  end.string
end

def render_c_file(code)
  StringIO.new('zkrb_wrapper.c', 'w') do |fp|
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
      fp.puts "#{wrap_fn.body}\n"
      fp.puts "#{call_fn.body}\n"
    end

  end.string
end

def main
  text = File.read('c/include/zookeeper.h')
  code = GeneratedCode.from_zookeeper_h(text)

  File.open(ZKRB_WRAPPER_H_PATH, 'w') { |fp| fp.write(render_header_file(code)) }
  File.open(ZKRB_WRAPPER_C_PATH, 'w') { |fp| fp.write(render_c_file(code)) }
end

main

