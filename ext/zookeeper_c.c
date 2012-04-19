/* Ruby wrapper for the Zookeeper C API
 * Phillip Pearson <pp@myelin.co.nz>
 * Eric Maland <eric@twitter.com>
 * Brian Wickman <wickman@twitter.com>
 *
 * This fork is a 90% rewrite of the original.  It takes a more evented
 * approach to isolate the ZK state machine from the ruby interpreter via an
 * event queue.  It's similar to the ZookeeperFFI version except that it
 * actually works on MRI 1.8.
 */

#define THREADED

#include "ruby.h"
#include "c-client-src/zookeeper.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/fcntl.h>
#include <pthread.h>
#include <inttypes.h>

#include "zookeeper_lib.h"
#include "dbg.h"

static VALUE Zookeeper = Qnil;
static VALUE ZookeeperClientId = Qnil;

// slyphon: possibly add a lock to this for synchronizing during get_next_event

struct zkrb_instance_data {
  zhandle_t            *zh;
  clientid_t          myid;
  zkrb_queue_t      *queue;
  long              object_id; // the ruby object this instance data is associated with
};

typedef enum {
  SYNC  = 0,
  ASYNC = 1,
  SYNC_WATCH = 2,
  ASYNC_WATCH = 3
} zkrb_call_type;

#define IS_SYNC(zkrbcall) ((zkrbcall)==SYNC || (zkrbcall)==SYNC_WATCH)
#define IS_ASYNC(zkrbcall) ((zkrbcall)==ASYNC || (zkrbcall)==ASYNC_WATCH)


static int destroy_zkrb_instance(struct zkrb_instance_data* ptr) {
  int rv = ZOK;

  if (ptr->zh) {
    const void *ctx = zoo_get_context(ptr->zh);
    /* Note that after zookeeper_close() returns, ZK handle is invalid */
    zkrb_debug("obj_id: %lx, calling zookeeper_close", ptr->object_id);
    rv = zookeeper_close(ptr->zh);
    zkrb_debug("obj_id: %lx, zookeeper_close returned %d", ptr->object_id, rv); 
    free((void *) ctx);
  }

#warning [wickman] TODO: fire off warning if queue is not empty
  if (ptr->queue) {
    zkrb_debug("obj_id: %lx, freeing queue pointer: %p", ptr->object_id, ptr->queue);
    zkrb_queue_free(ptr->queue);
  }

  ptr->zh = NULL;
  ptr->queue = NULL;

  return rv;
}

static void free_zkrb_instance_data(struct zkrb_instance_data* ptr) {
  destroy_zkrb_instance(ptr);
}

static void print_zkrb_instance_data(struct zkrb_instance_data* ptr) {
  fprintf(stderr, "zkrb_instance_data (%p) {\n", ptr);
  fprintf(stderr, "      zh = %p\n",           ptr->zh);
  fprintf(stderr, "        { state = %d }\n",  zoo_state(ptr->zh));
  fprintf(stderr, "      id = %"PRId64"\n",    ptr->myid.client_id);   // PRId64 defined in inttypes.h
  fprintf(stderr, "       q = %p\n",           ptr->queue);
  fprintf(stderr, "  obj_id = %lx\n",          ptr->object_id);
  fprintf(stderr, "}\n");
}

// cargo culted from io.c
static VALUE zkrb_new_instance _((VALUE));

static VALUE zkrb_new_instance(VALUE args) {
    return rb_class_new_instance(2, (VALUE*)args+1, *(VALUE*)args);
}

static int zkrb_dup(int orig) {
    int fd;

    fd = dup(orig);
    if (fd < 0) {
        if (errno == EMFILE || errno == ENFILE || errno == ENOMEM) {
            rb_gc();
            fd = dup(orig);
        }
        if (fd < 0) {
            rb_sys_fail(0);
        }
    }
    return fd;
}

static VALUE create_selectable_io(zkrb_queue_t *q) {
  // rb_cIO is the ruby IO class?

  int pipe, state, read_fd;
  VALUE args[3], reader;

  read_fd = zkrb_dup(q->pipe_read);

  args[0] = rb_cIO;
  args[1] = INT2NUM(read_fd);
  args[2] = INT2FIX(O_RDONLY);
  reader = rb_protect(zkrb_new_instance, (VALUE)args, &state);

  if (state) {
    rb_jump_tag(state);
  }

  return reader;
}

#define session_timeout_msec(self) rb_iv_get(self, "@_session_timeout_msec")

static VALUE method_init(int argc, VALUE* argv, VALUE self) {
  VALUE hostPort;
  VALUE options;

  rb_scan_args(argc, argv, "11", &hostPort, &options);

  if (NIL_P(options)) {
    options = rb_hash_new();
  } else {
    Check_Type(options, T_HASH);
  }

  Check_Type(hostPort, T_STRING);

  // Look up :zkc_log_level
  VALUE log_level = rb_hash_aref(options, ID2SYM(rb_intern("zkc_log_level")));
  if (NIL_P(log_level)) {
    zoo_set_debug_level(0); // no log messages
  } else {
    Check_Type(log_level, T_FIXNUM);
    zoo_set_debug_level((int)log_level);
  }


  VALUE data;
  struct zkrb_instance_data *zk_local_ctx;
  data = Data_Make_Struct(Zookeeper, struct zkrb_instance_data, 0, free_zkrb_instance_data, zk_local_ctx);
  zk_local_ctx->queue = zkrb_queue_alloc();

  zoo_deterministic_conn_order(0);

  zkrb_calling_context *ctx =
    zkrb_calling_context_alloc(ZKRB_GLOBAL_REQ, zk_local_ctx->queue);

  zk_local_ctx->object_id = FIX2LONG(rb_obj_id(self));

  zk_local_ctx->zh =
      zookeeper_init(
          RSTRING_PTR(hostPort),
          zkrb_state_callback,
          session_timeout_msec(self),
          &zk_local_ctx->myid,
          ctx,
          0);

#warning [wickman] TODO handle this properly on the Ruby side rather than C side
  if (!zk_local_ctx->zh) {
    rb_raise(rb_eRuntimeError, "error connecting to zookeeper: %d", errno);
  }

  rb_iv_set(self, "@_data", data);
  rb_iv_set(self, "@selectable_io", create_selectable_io(zk_local_ctx->queue));

  rb_funcall(self, rb_intern("zkc_set_running_and_notify!"), 0);

  return Qnil;
}

#define FETCH_DATA_PTR(x, y)                                            \
  struct zkrb_instance_data * y;                                        \
  Data_Get_Struct(rb_iv_get(x, "@_data"), struct zkrb_instance_data, y); \
  if ((y)->zh == NULL)                                                  \
    rb_raise(rb_eRuntimeError, "zookeeper handle is closed")

#define STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, cb_ctx, w_ctx, call_type) \
  if (TYPE(reqid) != T_FIXNUM && TYPE(reqid) != T_BIGNUM) {             \
    rb_raise(rb_eTypeError, "reqid must be Fixnum/Bignum");             \
    return Qnil;                                                        \
  }                                                                     \
  Check_Type(path, T_STRING);                                           \
  struct zkrb_instance_data * zk;                                       \
  Data_Get_Struct(rb_iv_get(self, "@_data"), struct zkrb_instance_data, zk); \
  if (!zk->zh)                                                          \
    rb_raise(rb_eRuntimeError, "zookeeper handle is closed");           \
  zkrb_calling_context* cb_ctx =                                        \
    (async != Qfalse && async != Qnil) ?                                \
       zkrb_calling_context_alloc(NUM2LL(reqid), zk->queue) :           \
       NULL;                                                            \
  zkrb_calling_context* w_ctx =                                         \
    (watch != Qfalse && watch != Qnil) ?                                \
       zkrb_calling_context_alloc(NUM2LL(reqid), zk->queue) :           \
       NULL;                                                            \
  int a  = (async != Qfalse && async != Qnil);                          \
  int w  = (watch != Qfalse && watch != Qnil);                          \
  zkrb_call_type call_type;                                             \
  if (a) { if (w) { call_type = ASYNC_WATCH; } else { call_type = ASYNC; } } \
    else { if (w) { call_type =  SYNC_WATCH; } else { call_type = SYNC; } }

static VALUE method_get_children(VALUE self, VALUE reqid, VALUE path, VALUE async, VALUE watch) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  struct String_vector strings;
  struct Stat stat;

  int rc;
  switch (call_type) {
    case SYNC:
      rc = zoo_get_children2(zk->zh, RSTRING_PTR(path), 0, &strings, &stat);
      break;

    case SYNC_WATCH:
      rc = zoo_wget_children2(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, &strings, &stat);
      break;

    case ASYNC:
      rc = zoo_aget_children2(zk->zh, RSTRING_PTR(path), 0, zkrb_strings_stat_callback, data_ctx);
      break;

    case ASYNC_WATCH:
      rc = zoo_awget_children2(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, zkrb_strings_stat_callback, data_ctx);
      break;
  }

  VALUE output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_string_vector_to_ruby(&strings));
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  return output;
}

static VALUE method_exists(VALUE self, VALUE reqid, VALUE path, VALUE async, VALUE watch) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  struct Stat stat;

  int rc;
  switch (call_type) {
    case SYNC:
      rc = zoo_exists(zk->zh, RSTRING_PTR(path), 0, &stat);
      break;

    case SYNC_WATCH:
      rc = zoo_wexists(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, &stat);
      break;

    case ASYNC:
      rc = zoo_aexists(zk->zh, RSTRING_PTR(path), 0, zkrb_stat_callback, data_ctx);
      break;

    case ASYNC_WATCH:
      rc = zoo_awexists(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, zkrb_stat_callback, data_ctx);
      break;
  }

  VALUE output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  return output;
}

// this method is *only* called asynchronously
static VALUE method_sync(VALUE self, VALUE reqid, VALUE path) {
  VALUE async = Qtrue;
  VALUE watch = Qfalse;
  int rc;

  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  rc = zoo_async(zk->zh, RSTRING_PTR(path), zkrb_string_callback, data_ctx);

  return INT2FIX(rc);
}

static VALUE method_create(VALUE self, VALUE reqid, VALUE path, VALUE data, VALUE async, VALUE acls, VALUE flags) {
  VALUE watch = Qfalse;
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  if (data != Qnil) Check_Type(data, T_STRING);
  Check_Type(flags, T_FIXNUM);
  const char *data_ptr = (data == Qnil) ? NULL : RSTRING_PTR(data);
  size_t      data_len = (data == Qnil) ? -1   : RSTRING_LEN(data);

  struct ACL_vector *aclptr = NULL;
  if (acls != Qnil) { aclptr = zkrb_ruby_to_aclvector(acls); }
  char realpath[16384];

  int rc;
  switch (call_type) {
    case SYNC:
      // casting data_len to int is OK as you can only store 1MB in zookeeper
      rc = zoo_create(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, aclptr, FIX2INT(flags), realpath, sizeof(realpath));
      break;
    case ASYNC:
      rc = zoo_acreate(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, aclptr, FIX2INT(flags), zkrb_string_callback, data_ctx);
      break;
    default:
      /* TODO(wickman) raise proper argument error */
      return Qnil;
      break;
  }

  if (aclptr) {
    deallocate_ACL_vector(aclptr);
    free(aclptr);
  }

  VALUE output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    return rb_ary_push(output, rb_str_new2(realpath));
  }
  return output;
}

static VALUE method_delete(VALUE self, VALUE reqid, VALUE path, VALUE version, VALUE async) {
  VALUE watch = Qfalse;
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);
  Check_Type(version, T_FIXNUM);

  int rc = 0;
  switch (call_type) {
    case SYNC:
      rc = zoo_delete(zk->zh, RSTRING_PTR(path), FIX2INT(version));
      break;
    case ASYNC:
      rc = zoo_adelete(zk->zh, RSTRING_PTR(path), FIX2INT(version), zkrb_void_callback, data_ctx);
      break;
    default:
      /* TODO(wickman) raise proper argument error */
      return Qnil;
      break;
  }

  return INT2FIX(rc);
}

#define MAX_ZNODE_SIZE 1048576

static VALUE method_get(VALUE self, VALUE reqid, VALUE path, VALUE async, VALUE watch) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  /* ugh */
  char * data = malloc(MAX_ZNODE_SIZE);
  int data_len = MAX_ZNODE_SIZE;
  struct Stat stat;

  int rc;

  switch (call_type) {
    case SYNC:
      rc = zoo_get(zk->zh, RSTRING_PTR(path), 0, data, &data_len, &stat);
      break;

    case SYNC_WATCH:
      rc = zoo_wget(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, data, &data_len, &stat);
      break;

    case ASYNC:
      rc = zoo_aget(zk->zh, RSTRING_PTR(path), 0, zkrb_data_callback, data_ctx);
      break;

    case ASYNC_WATCH:
      rc = zoo_awget(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, zkrb_data_callback, data_ctx);
      break;
  }

  VALUE output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    if (data_len == -1)
      rb_ary_push(output, Qnil);        /* No data associated with path */
    else
      rb_ary_push(output, rb_str_new(data, data_len));
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  free(data);

  return output;
}

static VALUE method_set(VALUE self, VALUE reqid, VALUE path, VALUE data, VALUE async, VALUE version) {
  VALUE watch = Qfalse;
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  struct Stat stat;
  if (data != Qnil) Check_Type(data, T_STRING);
  const char *data_ptr = (data == Qnil) ? NULL : RSTRING_PTR(data);
  size_t      data_len = (data == Qnil) ? -1   : RSTRING_LEN(data);

  int rc;
  switch (call_type) {
    case SYNC:
      rc = zoo_set2(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, FIX2INT(version), &stat);
      break;
    case ASYNC:
      rc = zoo_aset(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, FIX2INT(version),
                            zkrb_stat_callback, data_ctx);
      break;
    default:
      /* TODO(wickman) raise proper argument error */
      return Qnil;
      break;
  }

  VALUE output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  return output;
}

static VALUE method_set_acl(VALUE self, VALUE reqid, VALUE path, VALUE acls, VALUE async, VALUE version) {
  VALUE watch = Qfalse;
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);
  struct ACL_vector * aclptr = zkrb_ruby_to_aclvector(acls);

  int rc;
  switch (call_type) {
    case SYNC:
      rc = zoo_set_acl(zk->zh, RSTRING_PTR(path), FIX2INT(version), aclptr);
      break;
    case ASYNC:
      rc = zoo_aset_acl(zk->zh, RSTRING_PTR(path), FIX2INT(version), aclptr, zkrb_void_callback, data_ctx);
      break;
    default:
      /* TODO(wickman) raise proper argument error */
      return Qnil;
      break;
  }

  deallocate_ACL_vector(aclptr);
  free(aclptr);

  return INT2FIX(rc);
}

static VALUE method_get_acl(VALUE self, VALUE reqid, VALUE path, VALUE async) {
  VALUE watch = Qfalse;
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  struct ACL_vector acls;
  struct Stat stat;

  int rc;
  switch (call_type) {
    case SYNC:
      rc = zoo_get_acl(zk->zh, RSTRING_PTR(path), &acls, &stat);
      break;
    case ASYNC:
      rc = zoo_aget_acl(zk->zh, RSTRING_PTR(path), zkrb_acl_callback, data_ctx);
      break;
    default:
      /* TODO(wickman) raise proper argument error */
      return Qnil;
      break;
  }

  VALUE output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_acl_vector_to_ruby(&acls));
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
    deallocate_ACL_vector(&acls);
  }
  return output;
}

static int is_running(VALUE self) {
  VALUE rval = rb_iv_get(self, "@_running");
  return RTEST(rval);
}

static int is_closed(VALUE self) {
  VALUE rval = rb_iv_get(self, "@_closed");
  return RTEST(rval);
}

static int is_shutting_down(VALUE self) {
  VALUE rval = rb_iv_get(self, "@_shutting_down");
  return RTEST(rval);
}

/* slyphon: NEED TO PROTECT THIS AGAINST SHUTDOWN */

static VALUE method_get_next_event(VALUE self, VALUE blocking) {
  // dbg.h 
  check_debug(!is_closed(self), "we are closed, not trying to get event");

  char buf[64];
  FETCH_DATA_PTR(self, zk);

  for (;;) {
    check_debug(!is_closed(self), "we're closed in the middle of method_get_next_event, bailing");

    zkrb_event_t *event = zkrb_dequeue(zk->queue, 1);

    /* Wait for an event using rb_thread_select() on the queue's pipe */
    if (event == NULL) {
      if (NIL_P(blocking) || (blocking == Qfalse)) { 
        goto error;
      } 
      else {
        // if we're shutting down, don't enter this section, we don't want to block
        check_debug(!is_shutting_down(self), "method_get_next_event, we're shutting down, don't enter blocking section");

        int fd = zk->queue->pipe_read;
        ssize_t bytes_read = 0;

        // wait for an fd to become readable, opposite of rb_thread_fd_writable
        rb_thread_wait_fd(fd);

        // clear all bytes here, we'll catch all the events on subsequent calls
        // (until we run out of events)
        bytes_read = read(fd, buf, sizeof(buf));

        if (bytes_read == -1) {
          rb_raise(rb_eRuntimeError, "read failed: %d", errno);
        }

        zkrb_debug_inst(self, "read %zd bytes from the queue (%p)'s pipe", bytes_read, zk->queue);

        continue;
      }
    }

    VALUE hash = zkrb_event_to_ruby(event);
    zkrb_event_free(event);
    return hash;
  }

  error: 
    return Qnil;
}

static VALUE method_has_events(VALUE self) {
  VALUE rb_event;
  FETCH_DATA_PTR(self, zk);

  rb_event = zkrb_peek(zk->queue) != NULL ? Qtrue : Qfalse;
  return rb_event;
}


// wake up the event loop, used when shutting down
static VALUE method_wake_event_loop_bang(VALUE self) {
  FETCH_DATA_PTR(self, zk); 

  zkrb_debug_inst(self, "Waking event loop: %p", zk->queue);
  zkrb_signal(zk->queue);

  return Qnil;
};

// static VALUE method_signal_pending_close(VALUE self) {
//   FETCH_DATA_PTR(self, zk);
// 
//   zk->pending_close = 1;
//   zkrb_signal(zk->queue);
// 
//   return Qnil;
// }

static VALUE method_close_handle(VALUE self) {
  FETCH_DATA_PTR(self, zk);

  if (ZKRBDebugging) {
/*    fprintf(stderr, "CLOSING ZK INSTANCE: obj_id %lx", FIX2LONG(rb_obj_id(self)));*/
    zkrb_debug_inst(self, "CLOSING_ZK_INSTANCE");
    print_zkrb_instance_data(zk);
  }
  
  // this is a value on the ruby side we can check to see if destroy_zkrb_instance
  // has been called
  rb_iv_set(self, "@_closed", Qtrue);

  zkrb_debug_inst(self, "calling destroy_zkrb_instance");

  /* Note that after zookeeper_close() returns, ZK handle is invalid */
  int rc = destroy_zkrb_instance(zk);

  zkrb_debug("destroy_zkrb_instance returned: %d", rc);

  return Qnil;
/*  return INT2FIX(rc);*/
}

static VALUE method_deterministic_conn_order(VALUE self, VALUE yn) {
  zoo_deterministic_conn_order(yn == Qtrue);
  return Qnil;
}

static VALUE method_is_unrecoverable(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  return is_unrecoverable(zk->zh) == ZINVALIDSTATE ? Qtrue : Qfalse;
}

static VALUE method_zkc_state(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  return INT2NUM(zoo_state(zk->zh));
}

static VALUE method_recv_timeout(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  return INT2NUM(zoo_recv_timeout(zk->zh));
}

/*static VALUE method_client_id(VALUE self) {*/
/*  FETCH_DATA_PTR(self, zk);*/
/*  const clientid_t *id = zoo_client_id(zk->zh);*/
/*  return UINT2NUM(id->client_id);*/
/*}*/


// returns a CZookeeper::ClientId object with the values set for session_id and passwd
static VALUE method_client_id(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  const clientid_t *cid = zoo_client_id(zk->zh);

  VALUE session_id = LL2NUM(cid->client_id);
  VALUE passwd = rb_str_new2(cid->passwd);

  VALUE client_id_obj = rb_class_new_instance(0, RARRAY_PTR(rb_ary_new()), ZookeeperClientId);

  rb_funcall(client_id_obj, rb_intern("session_id="), 1, session_id);
  rb_funcall(client_id_obj, rb_intern("passwd="), 1, passwd);

  return client_id_obj;
}

static VALUE klass_method_set_debug_level(VALUE klass, VALUE level) {
  Check_Type(level, T_FIXNUM);
  ZKRBDebugging = (FIX2INT(level) == ZOO_LOG_LEVEL_DEBUG);
  zoo_set_debug_level(FIX2INT(level));
  return Qnil;
}

static VALUE method_zerror(VALUE self, VALUE errc) {
  return rb_str_new2(zerror(FIX2INT(errc)));
}

static void zkrb_define_methods(void) {
#define DEFINE_METHOD(method, args) { \
    rb_define_method(Zookeeper, #method, method_ ## method, args); }
#define DEFINE_CLASS_METHOD(method, args) { \
    rb_define_singleton_method(Zookeeper, #method, method_ ## method, args); }

  // the number after the method name should be actual arity of C function - 1
  DEFINE_METHOD(init, -1);
  DEFINE_METHOD(get_children, 4);
  DEFINE_METHOD(exists, 4);
  DEFINE_METHOD(create, 6);
  DEFINE_METHOD(delete, 4);
  DEFINE_METHOD(get, 4);
  DEFINE_METHOD(set, 5);
  DEFINE_METHOD(set_acl, 5);
  DEFINE_METHOD(get_acl, 3);
  DEFINE_METHOD(client_id, 0);
  DEFINE_METHOD(close_handle, 0);
  DEFINE_METHOD(deterministic_conn_order, 1);
  DEFINE_METHOD(is_unrecoverable, 0);
  DEFINE_METHOD(recv_timeout, 1);
  DEFINE_METHOD(zkc_state, 0);
  DEFINE_METHOD(sync, 2);

  // TODO
  // DEFINE_METHOD(add_auth, 3);

  // methods for the ruby-side event manager
  DEFINE_METHOD(get_next_event, 1);
  DEFINE_METHOD(has_events, 0);

  // Make these class methods?
  DEFINE_METHOD(zerror, 1);

  rb_define_singleton_method(Zookeeper, "set_debug_level", klass_method_set_debug_level, 1);

  rb_attr(Zookeeper, rb_intern("selectable_io"), 1, 0, Qtrue);

  rb_define_method(Zookeeper, "wake_event_loop!", method_wake_event_loop_bang, 0);
}

// class CZookeeper::ClientId
//   attr_accessor :session_id, :passwd
//
//   def initialize(session_id, passwd)
//     @session_id = session_id
//     @passwd = passwd
//   end
// end

static VALUE zkrb_client_id_method_initialize(VALUE self) {
  rb_iv_set(self, "@session_id", Qnil);
  rb_iv_set(self, "@passwd", Qnil);
  return Qnil;
}

void Init_zookeeper_c() {
  ZKRBDebugging = 0;
  /* initialize Zookeeper class */
  Zookeeper = rb_define_class("CZookeeper", rb_cObject);
  zkrb_define_methods();

  ZookeeperClientId = rb_define_class_under(Zookeeper, "ClientId", rb_cObject);
  rb_define_method(ZookeeperClientId, "initialize", zkrb_client_id_method_initialize, 0);
  rb_define_attr(ZookeeperClientId, "session_id", 1, 1);
  rb_define_attr(ZookeeperClientId, "passwd", 1, 1);
}

// vim:ts=2:sw=2:sts=2:et
