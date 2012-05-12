/* Ruby wrapper for the Zookeeper C API
 * Phillip Pearson <pp@myelin.co.nz>
 * Eric Maland <eric@twitter.com>
 * Brian Wickman <wickman@twitter.com>
 * Jonathan D. Simms <slyphon@gmail.com>
 *
 * This fork is a 90% rewrite of the original.  It takes a more evented
 * approach to isolate the ZK state machine from the ruby interpreter via an
 * event queue.  It's similar to the ZookeeperFFI version except that it
 * actually works on MRI 1.8.
 */

//#define THREADED
#undef THREADED

#include "ruby.h"
#include "c-client-src/zookeeper.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/fcntl.h>
#include <pthread.h>
#include <inttypes.h>
#include <time.h>

#include "event_lib.h"
#include "zkrb_wrapper.h"
#include "dbg.h"

static VALUE mZookeeper = Qnil;         // the Zookeeper module
static VALUE CZookeeper = Qnil;         // the Zookeeper::CZookeeper class
static VALUE ZookeeperClientId = Qnil;

// slyphon: possibly add a lock to this for synchronizing during get_next_event

struct zkrb_instance_data {
  zhandle_t            *zh;
  clientid_t          myid;
  zkrb_queue_t      *queue;
  long              object_id; // the ruby object this instance data is associated with
  pid_t             orig_pid;
};

typedef struct zkrb_instance_data zkrb_instance_data_t;

typedef enum {
  SYNC  = 0,
  ASYNC = 1,
  SYNC_WATCH = 2,
  ASYNC_WATCH = 3
} zkrb_call_type;

#define IS_SYNC(zkrbcall) ((zkrbcall)==SYNC || (zkrbcall)==SYNC_WATCH)
#define IS_ASYNC(zkrbcall) ((zkrbcall)==ASYNC || (zkrbcall)==ASYNC_WATCH)

static void hexbufify(char *dest, const char *src, int len) {
  int i=0;

  for (i=0; i < len; i++) {
    sprintf(&dest[i*2], "%x", src[i]);
  }
}

static int destroy_zkrb_instance(zkrb_instance_data_t* ptr) {
  int rv = ZOK;

  zkrb_debug("destroy_zkrb_instance, zk_local_ctx: %p, zh: %p, queue: %p", ptr, ptr->zh, ptr->queue);

  if (ptr->zh) {
    const void *ctx = zoo_get_context(ptr->zh);
    /* Note that after zookeeper_close() returns, ZK handle is invalid */
    zkrb_debug("obj_id: %lx, calling zookeeper_close", ptr->object_id);

    rv = zookeeper_close(ptr->zh);

    zkrb_debug("obj_id: %lx, zookeeper_close returned %d", ptr->object_id, rv); 
    free((void *) ctx);
  }

  ptr->zh = NULL;

// [wickman] TODO: fire off warning if queue is not empty
  if (ptr->queue) {
    zkrb_debug("obj_id: %lx, freeing queue pointer: %p", ptr->object_id, ptr->queue);
    zkrb_queue_free(ptr->queue);
  }

  ptr->queue = NULL;

  return rv;
}

static void free_zkrb_instance_data(zkrb_instance_data_t* ptr) {
  destroy_zkrb_instance(ptr);
}

static void print_zkrb_instance_data(zkrb_instance_data_t* ptr) {
  fprintf(stderr, "zkrb_instance_data (%p) {\n", ptr);
  fprintf(stderr, "      zh = %p\n",           ptr->zh);
  fprintf(stderr, "        { state = %d }\n",  zoo_state(ptr->zh));
  fprintf(stderr, "      id = %"PRId64"\n",    ptr->myid.client_id);   // PRId64 defined in inttypes.h
  fprintf(stderr, "       q = %p\n",           ptr->queue);
  fprintf(stderr, "  obj_id = %lx\n",          ptr->object_id);
  fprintf(stderr, "}\n");
}


#define session_timeout_msec(self) rb_iv_get(self, "@_session_timeout_msec")

inline static void zkrb_debug_clientid_t(const clientid_t *cid) {
  int pass_len = sizeof(cid->passwd);
  int hex_len = 2 * pass_len;
  char buf[hex_len];
  hexbufify(buf, cid->passwd, pass_len);

  zkrb_debug("myid, client_id: %"PRId64", passwd: %*s", cid->client_id, hex_len, buf);
}

static VALUE method_zkrb_init(int argc, VALUE* argv, VALUE self) {
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
  zkrb_instance_data_t *zk_local_ctx;
  data = Data_Make_Struct(CZookeeper, zkrb_instance_data_t, 0, free_zkrb_instance_data, zk_local_ctx);

  zk_local_ctx->queue = zkrb_queue_alloc();

  if (zk_local_ctx->queue == NULL)
    rb_raise(rb_eRuntimeError, "could not allocate zkrb queue!");

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

  zkrb_debug("method_zkrb_init, zk_local_ctx: %p, zh: %p, queue: %p, calling_ctx: %p",
      zk_local_ctx, zk_local_ctx->zh, zk_local_ctx->queue, ctx);

// [wickman] TODO handle this properly on the Ruby side rather than C side
  if (!zk_local_ctx->zh) {
    rb_raise(rb_eRuntimeError, "error connecting to zookeeper: %d", errno);
  }

  zk_local_ctx->orig_pid = getpid();

  rb_iv_set(self, "@_data", data);
  rb_funcall(self, rb_intern("zkc_set_running_and_notify!"), 0);

  return Qnil;
}

#define FETCH_DATA_PTR(X, Y)                                             \
  zkrb_instance_data_t * Y;                                         \
  Data_Get_Struct(rb_iv_get(X, "@_data"), zkrb_instance_data_t, Y); \
  if ((Y)->zh == NULL)                                                   \
    rb_raise(rb_eRuntimeError, "zookeeper handle is closed")

#define STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, cb_ctx, w_ctx, call_type) \
  if (TYPE(reqid) != T_FIXNUM && TYPE(reqid) != T_BIGNUM) {                   \
    rb_raise(rb_eTypeError, "reqid must be Fixnum/Bignum");                   \
    return Qnil;                                                              \
  }                                                                           \
  Check_Type(path, T_STRING);                                                 \
  zkrb_instance_data_t * zk;                                             \
  Data_Get_Struct(rb_iv_get(self, "@_data"), zkrb_instance_data_t, zk);  \
  if (!zk->zh)                                                                \
    rb_raise(rb_eRuntimeError, "zookeeper handle is closed");                 \
  zkrb_calling_context* cb_ctx =                                              \
    (async != Qfalse && async != Qnil) ?                                      \
       zkrb_calling_context_alloc(NUM2LL(reqid), zk->queue) :                 \
       NULL;                                                                  \
  zkrb_calling_context* w_ctx =                                               \
    (watch != Qfalse && watch != Qnil) ?                                      \
       zkrb_calling_context_alloc(NUM2LL(reqid), zk->queue) :                 \
       NULL;                                                                  \
  int a_  = (async != Qfalse && async != Qnil);                               \
  int w_  = (watch != Qfalse && watch != Qnil);                               \
  zkrb_call_type call_type;                                                   \
  if (a_) { if (w_) { call_type = ASYNC_WATCH; } else { call_type = ASYNC; } } \
     else { if (w_) { call_type =  SYNC_WATCH; } else { call_type = SYNC; } }

static VALUE method_get_children(VALUE self, VALUE reqid, VALUE path, VALUE async, VALUE watch) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, data_ctx, watch_ctx, call_type);

  struct String_vector strings;
  struct Stat stat;

  int rc;
  switch (call_type) {
    case SYNC:
      rc = zkrb_call_zoo_get_children2(zk->zh, RSTRING_PTR(path), 0, &strings, &stat);
      break;

    case SYNC_WATCH:
      rc = zkrb_call_zoo_wget_children2(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, &strings, &stat);
      break;

    case ASYNC:
      rc = zkrb_call_zoo_aget_children2(zk->zh, RSTRING_PTR(path), 0, zkrb_strings_stat_callback, data_ctx);
      break;

    case ASYNC_WATCH:
      rc = zkrb_call_zoo_awget_children2(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, zkrb_strings_stat_callback, data_ctx);
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
      rc = zkrb_call_zoo_exists(zk->zh, RSTRING_PTR(path), 0, &stat);
      break;

    case SYNC_WATCH:
      rc = zkrb_call_zoo_wexists(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, &stat);
      break;

    case ASYNC:
      rc = zkrb_call_zoo_aexists(zk->zh, RSTRING_PTR(path), 0, zkrb_stat_callback, data_ctx);
      break;

    case ASYNC_WATCH:
      rc = zkrb_call_zoo_awexists(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, zkrb_stat_callback, data_ctx);
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

  rc = zkrb_call_zoo_async(zk->zh, RSTRING_PTR(path), zkrb_string_callback, data_ctx);

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
      rc = zkrb_call_zoo_create(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, aclptr, FIX2INT(flags), realpath, sizeof(realpath));

      break;
    case ASYNC:
      rc = zkrb_call_zoo_acreate(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, aclptr, FIX2INT(flags), zkrb_string_callback, data_ctx);

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
      rc = zkrb_call_zoo_delete(zk->zh, RSTRING_PTR(path), FIX2INT(version));
      break;
    case ASYNC:
      rc = zkrb_call_zoo_adelete(zk->zh, RSTRING_PTR(path), FIX2INT(version), zkrb_void_callback, data_ctx);
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
      rc = zkrb_call_zoo_get(zk->zh, RSTRING_PTR(path), 0, data, &data_len, &stat);
      break;

    case SYNC_WATCH:
      rc = zkrb_call_zoo_wget(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, data, &data_len, &stat);
      break;

    case ASYNC:
      rc = zkrb_call_zoo_aget(zk->zh, RSTRING_PTR(path), 0, zkrb_data_callback, data_ctx);
      break;

    case ASYNC_WATCH:
      rc = zkrb_call_zoo_awget(zk->zh, RSTRING_PTR(path), zkrb_state_callback, watch_ctx, zkrb_data_callback, data_ctx);
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
      rc = zkrb_call_zoo_set2(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, FIX2INT(version), &stat);
      break;
    case ASYNC:
      rc = zkrb_call_zoo_aset(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, FIX2INT(version),
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
      rc = zkrb_call_zoo_set_acl(zk->zh, RSTRING_PTR(path), FIX2INT(version), aclptr);
      break;
    case ASYNC:
      rc = zkrb_call_zoo_aset_acl(zk->zh, RSTRING_PTR(path), FIX2INT(version), aclptr, zkrb_void_callback, data_ctx);
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
      rc = zkrb_call_zoo_get_acl(zk->zh, RSTRING_PTR(path), &acls, &stat);
      break;
    case ASYNC:
      rc = zkrb_call_zoo_aget_acl(zk->zh, RSTRING_PTR(path), zkrb_acl_callback, data_ctx);
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

#define is_running(self) RTEST(rb_iv_get(self, "@_running"))
#define is_closed(self) RTEST(rb_iv_get(self, "@_closed"))
#define is_shutting_down(self) RTEST(rb_iv_get(self, "@_shutting_down"))

static VALUE method_zkrb_get_next_event(VALUE self, VALUE blocking) {
  // dbg.h 
  check_debug(!is_closed(self), "we are closed, not trying to get event");

  char buf[64];
  FETCH_DATA_PTR(self, zk);

  for (;;) {
    check_debug(!is_closed(self), "we're closed in the middle of method_zkrb_get_next_event, bailing");

    zkrb_event_t *event = zkrb_dequeue(zk->queue, 1);

    /* Wait for an event using rb_thread_select() on the queue's pipe */
    if (event == NULL) {
      if (NIL_P(blocking) || (blocking == Qfalse)) { 
        goto error;
      } 
      else {
        // if we're shutting down, don't enter this section, we don't want to block
        check_debug(!is_shutting_down(self), "method_zkrb_get_next_event, we're shutting down, don't enter blocking section");

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

// the single threaded version of this call. will go away when we do direct
// event delivery (soon)
static VALUE method_zkrb_get_next_event_st(VALUE self) {
  VALUE rval = Qnil;

  if (is_closed(self)) {
    zkrb_debug("we are closed, not gonna try to get an event");
    return Qnil;
  }

  FETCH_DATA_PTR(self, zk);

  zkrb_event_t *event = zkrb_dequeue(zk->queue, 0);

  if (event != NULL) {
    rval = zkrb_event_to_ruby(event);
    zkrb_event_free(event);

    char buf[1];
    int fd = zk->queue->pipe_read;
    ssize_t bytes_read = 0;

    bytes_read = read(fd, buf, sizeof(buf));

    if (bytes_read == -1) {
      rb_raise(rb_eRuntimeError, "read failed: %d", errno);
    }
  }

  return rval;
}

static VALUE method_zkrb_iterate_event_loop(VALUE self) {
  FETCH_DATA_PTR(self, zk);

  fd_set rfds, wfds, efds;
  FD_ZERO(&rfds); FD_ZERO(&wfds); FD_ZERO(&efds); 

  int fd=0, interest=0, events=0, rc=0;
  struct timeval tv;
  
  zookeeper_interest(zk->zh, &fd, &interest, &tv);

  if (fd != -1) {
    if (interest & ZOOKEEPER_READ) {
      FD_SET(fd, &rfds);
    } else {
      FD_CLR(fd, &rfds);
    }
    if (interest & ZOOKEEPER_WRITE) {
      FD_SET(fd, &wfds);
    } else {
      FD_CLR(fd, &wfds);
    }
  } else {
    fd = 0;
  }

/*  zkrb_debug("zookeeper_interest set timeval to %ld.%06d sec", tv.tv_sec, tv.tv_usec);*/

  // this is 0.001s, more reasonable when we're trying to loop through this and
  // also respond to stuff like shutdown
  tv.tv_sec = 0;
  tv.tv_usec = 10000;

  rc = rb_thread_select(fd+1, &rfds, &wfds, &efds, &tv);

  if (rc > 0) {
    if (FD_ISSET(fd, &rfds)) {
      events |= ZOOKEEPER_READ;
    } 
    if (FD_ISSET(fd, &wfds)) {
      events |= ZOOKEEPER_WRITE;
    }
  }

  rc = zookeeper_process(zk->zh, events);
  return INT2FIX(rc);
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

static VALUE method_close_handle(VALUE self) {
  FETCH_DATA_PTR(self, zk);

  if (ZKRBDebugging) {
    zkrb_debug_inst(self, "CLOSING_ZK_INSTANCE");
    print_zkrb_instance_data(zk);
  }
  
  // this is a value on the ruby side we can check to see if destroy_zkrb_instance
  // has been called
  rb_iv_set(self, "@_closed", Qtrue);

  /* Note that after zookeeper_close() returns, ZK handle is invalid */
  int rc = destroy_zkrb_instance(zk);

  zkrb_debug("destroy_zkrb_instance returned: %d", rc);

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

static VALUE method_zkrb_state(VALUE self) {
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
  char buf[32];
  const clientid_t *cid = zoo_client_id(zk->zh);

  if (strlen(cid->passwd) != 16) { 
    zkrb_debug("passwd is not null-termniated");
  } else {
    hexbufify(buf, cid->passwd, 16);
    zkrb_debug("password in hex is: %s", buf);
  }

  VALUE session_id = LL2NUM(cid->client_id);
  VALUE passwd = rb_str_new2(cid->passwd);

  VALUE client_id_obj = rb_class_new_instance(0, RARRAY_PTR(rb_ary_new()), ZookeeperClientId);

  rb_funcall(client_id_obj, rb_intern("session_id="), 1, session_id);
  rb_funcall(client_id_obj, rb_intern("passwd="), 1, passwd);

  return client_id_obj;
}

static VALUE klass_method_zkrb_set_debug_level(VALUE klass, VALUE level) {
  Check_Type(level, T_FIXNUM);
  ZKRBDebugging = (FIX2INT(level) == ZOO_LOG_LEVEL_DEBUG);
  zoo_set_debug_level(FIX2INT(level));
  return Qnil;
}

static VALUE method_zerror(VALUE self, VALUE errc) {
  return rb_str_new2(zerror(FIX2INT(errc)));
}

static void zkrb_define_methods(void) {
#define DEFINE_METHOD(M, ARGS) { \
    rb_define_method(CZookeeper, #M, method_ ## M, ARGS); }

#define DEFINE_CLASS_METHOD(M, ARGS) { \
    rb_define_singleton_method(CZookeeper, #M, method_ ## M, ARGS); }

// defines a method with a zkrb_ prefix, the actual C method does not have this prefix
#define DEFINE_ZKRB_METHOD(M, ARGS) { \
    rb_define_method(CZookeeper, zkrb_ ## M, method_ ## M, ARGS); }

  // the number after the method name should be actual arity of C function - 1
  DEFINE_METHOD(zkrb_init, -1);

  rb_define_method(CZookeeper, "zkrb_get_children", method_get_children,  4);
  rb_define_method(CZookeeper, "zkrb_exists",       method_exists,        4);
  rb_define_method(CZookeeper, "zkrb_create",       method_create,        6);
  rb_define_method(CZookeeper, "zkrb_delete",       method_delete,        4);
  rb_define_method(CZookeeper, "zkrb_get",          method_get,           4);
  rb_define_method(CZookeeper, "zkrb_set",          method_set,           5);
  rb_define_method(CZookeeper, "zkrb_set_acl",      method_set_acl,       5);
  rb_define_method(CZookeeper, "zkrb_get_acl",      method_get_acl,       3);


  DEFINE_METHOD(client_id, 0);
  DEFINE_METHOD(close_handle, 0);
  DEFINE_METHOD(deterministic_conn_order, 1);
  DEFINE_METHOD(is_unrecoverable, 0);
  DEFINE_METHOD(recv_timeout, 1);
  DEFINE_METHOD(zkrb_state, 0);
  DEFINE_METHOD(sync, 2);
  DEFINE_METHOD(zkrb_iterate_event_loop, 0);
  DEFINE_METHOD(zkrb_get_next_event_st, 0);

  // TODO
  // DEFINE_METHOD(add_auth, 3);

  // methods for the ruby-side event manager
  DEFINE_METHOD(zkrb_get_next_event, 1);
  DEFINE_METHOD(zkrb_get_next_event_st, 0);
  DEFINE_METHOD(has_events, 0);

  // Make these class methods?
  DEFINE_METHOD(zerror, 1);

  rb_define_singleton_method(CZookeeper, "set_zkrb_debug_level", klass_method_zkrb_set_debug_level, 1);

  rb_attr(CZookeeper, rb_intern("selectable_io"), 1, 0, Qtrue);
  rb_define_method(CZookeeper, "wake_event_loop!", method_wake_event_loop_bang, 0);

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

  mZookeeper = rb_define_module("Zookeeper");

  /* initialize CZookeeper class */
  CZookeeper = rb_define_class_under(mZookeeper, "CZookeeper", rb_cObject);
  zkrb_define_methods();

  ZookeeperClientId = rb_define_class_under(CZookeeper, "ClientId", rb_cObject);
  rb_define_method(ZookeeperClientId, "initialize", zkrb_client_id_method_initialize, 0);
  rb_define_attr(ZookeeperClientId, "session_id", 1, 1);
  rb_define_attr(ZookeeperClientId, "passwd", 1, 1);
}

// vim:ts=2:sw=2:sts=2:et
