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

#include "zookeeper_lib.h"

static VALUE Zookeeper = Qnil;

struct zkrb_instance_data {
  zhandle_t            *zh;
  clientid_t          myid;
  zkrb_queue_t      *queue;
};

typedef enum {
  SYNC  = 0,
  ASYNC = 1,
  SYNC_WATCH = 2,
  ASYNC_WATCH = 3
} zkrb_call_type;

#define IS_SYNC(zkrbcall) ((zkrbcall)==SYNC || (zkrbcall)==SYNC_WATCH)
#define IS_ASYNC(zkrbcall) ((zkrbcall)==ASYNC || (zkrbcall)==ASYNC_WATCH)

static void free_zkrb_instance_data(struct zkrb_instance_data* ptr) {
#warning [wickman] TODO: fire off warning if queue is not empty
  if (ptr->zh && zoo_state(ptr->zh) == ZOO_CONNECTED_STATE) {
    zookeeper_close(ptr->zh);
  }
  if (ptr->queue) zkrb_queue_free(ptr->queue);
  ptr->queue = NULL;
}

static void print_zkrb_instance_data(struct zkrb_instance_data* ptr) {
  fprintf(stderr, "zkrb_instance_data (%x) {\n", ptr);
  fprintf(stderr, "   zh = %x\n",           ptr->zh);
  fprintf(stderr, "     { state = %d }\n",  zoo_state(ptr->zh));
  fprintf(stderr, "   id = %llx\n",         ptr->myid.client_id);
  fprintf(stderr, "    q = %x\n",           ptr->queue);
  fprintf(stderr, "}\n");
}

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
    zoo_set_debug_level(log_level);
  }

  VALUE data;
  struct zkrb_instance_data *zk_local_ctx = NULL;
  data = Data_Make_Struct(Zookeeper,
           struct zkrb_instance_data,
           0,
           free_zkrb_instance_data,
           zk_local_ctx);
  zk_local_ctx->queue = zkrb_queue_alloc();

  zoo_deterministic_conn_order(0);

  zkrb_calling_context *ctx =
    zkrb_calling_context_alloc(ZKRB_GLOBAL_REQ, zk_local_ctx->queue);

  zk_local_ctx->zh = 
      zookeeper_init(
          RSTRING_PTR(hostPort),
          zkrb_state_callback,
          10000,
          &zk_local_ctx->myid,
          ctx,
          0);
  
#warning [wickman] TODO handle this properly on the Ruby side rather than C side
  if (!zk_local_ctx->zh) {
    rb_raise(rb_eRuntimeError, "error connecting to zookeeper: %d", errno);
  }

  rb_iv_set(self, "@data", data);

  return Qnil;
}

#define FETCH_DATA_PTR(x, y) \
  struct zkrb_instance_data * y; \
  Data_Get_Struct(rb_iv_get(x, "@data"), struct zkrb_instance_data, y)

#define STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, cb_ctx, w_ctx, call_type) \
  if (TYPE(reqid) != T_FIXNUM && TYPE(reqid) != T_BIGNUM) {             \
    rb_raise(rb_eTypeError, "reqid must be Fixnum/Bignum");             \
    return Qnil;                                                        \
  }                                                                     \
  Check_Type(path, T_STRING);                                           \
  struct zkrb_instance_data * zk;                                       \
  Data_Get_Struct(rb_iv_get(self, "@data"), struct zkrb_instance_data, zk); \
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

static VALUE method_create(VALUE self, VALUE reqid, VALUE path, VALUE data, VALUE async, VALUE acls, VALUE flags) {
  VALUE watch = Qfalse;
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);
  
  struct Stat stat;
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
      rc = zoo_create(zk->zh, RSTRING_PTR(path), data_ptr, data_len, aclptr, FIX2INT(flags), realpath, sizeof(realpath));
      if (aclptr != NULL) deallocate_ACL_vector(aclptr);
      break;
    case ASYNC:
      rc = zoo_acreate(zk->zh, RSTRING_PTR(path), data_ptr, data_len, aclptr, FIX2INT(flags), zkrb_string_callback, data_ctx);
      if (aclptr != NULL) deallocate_ACL_vector(aclptr);
      break;
    default:
      /* TODO(wickman) raise proper argument error */
      return Qnil;
      break;
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
      rc = zoo_set2(zk->zh, RSTRING_PTR(path), data_ptr, data_len, FIX2INT(version), &stat);
      break;
    case ASYNC:
      rc = zoo_aset(zk->zh, RSTRING_PTR(path), data_ptr, data_len, FIX2INT(version),
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
      deallocate_ACL_vector(aclptr);
      break;
    case ASYNC:
      rc = zoo_aset_acl(zk->zh, RSTRING_PTR(path), FIX2INT(version), aclptr, zkrb_void_callback, data_ctx);
      deallocate_ACL_vector(aclptr);
      break;
    default:
      /* TODO(wickman) raise proper argument error */
      return Qnil;
      break;
  }

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

  // do we need to deallocate the strings in the acl vector????
  VALUE output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_acl_vector_to_ruby(&acls));
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  return output;
}

static VALUE method_get_next_event(VALUE self) {
  FETCH_DATA_PTR(self, zk);

  zkrb_event_t *event = zkrb_dequeue(zk->queue);
  if (event == NULL) return Qnil;

  VALUE hash = zkrb_event_to_ruby(event);
  zkrb_event_free(event);
  return hash;
}

static VALUE method_has_events(VALUE self) {
  VALUE rb_event = NULL;
  FETCH_DATA_PTR(self, zk);

  pthread_mutex_lock(&zkrb_q_mutex);
  rb_event = zkrb_peek(zk->queue) != NULL ? Qtrue : Qfalse;
  pthread_mutex_unlock(&zkrb_q_mutex);
  return rb_event;
}

static VALUE method_client_id(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  const clientid_t *id = zoo_client_id(zk->zh);
  return UINT2NUM(id->client_id);
}

static VALUE method_close(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  int rc = zookeeper_close(zk->zh);
  return INT2FIX(rc);
}

static VALUE method_deterministic_conn_order(VALUE self, VALUE yn) {
  zoo_deterministic_conn_order(yn == Qtrue);
  return Qnil;
}

static VALUE method_is_unrecoverable(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  return is_unrecoverable(zk->zh) == ZINVALIDSTATE ? Qtrue : Qfalse;
}

static VALUE method_state(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  return INT2NUM(zoo_state(zk->zh));
}

static VALUE method_recv_timeout(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  return INT2NUM(zoo_recv_timeout(zk->zh));
}

// how do you make a class method??
static VALUE method_set_debug_level(VALUE self, VALUE level) {
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
  DEFINE_METHOD(close, 0);
  DEFINE_METHOD(deterministic_conn_order, 1);
  DEFINE_METHOD(is_unrecoverable, 0);
  DEFINE_METHOD(recv_timeout, 1);
  DEFINE_METHOD(state, 0);
  // TODO
  // DEFINE_METHOD(add_auth, 3);
  // DEFINE_METHOD(async, 1);

  // methods for the ruby-side event manager  
  DEFINE_METHOD(get_next_event, 0);
  DEFINE_METHOD(has_events, 0);

  // Make these class methods?  
  DEFINE_METHOD(set_debug_level, 1);
  DEFINE_METHOD(zerror, 1);
}
void Init_zookeeper_c() {
  ZKRBDebugging = 0;
  pthread_mutex_init(&zkrb_q_mutex, NULL);
  /* initialize Zookeeper class */
  Zookeeper = rb_define_class("CZookeeper", rb_cObject);
  zkrb_define_methods();
}
