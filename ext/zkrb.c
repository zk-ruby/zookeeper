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
 *
 *----------------
 * (slyphon)
 *
 * Wickman's implementation was linked against the 'mt' version of the zookeeper
 * library, which is multithreaded at the zookeeper level and is subsequently
 * much more difficult to get to behave properly with the ruby runtime (which
 * he did, and I could never have written).
 *
 * The current implementation has been converted to use the 'st' version of the
 * zookeeper library, which is single threaded and requires a ruby-side event
 * loop. This is essentially a ruby port of the code running in the 'mt'
 * library, with one important difference: It's running in ruby-land. The
 * reason this change is so important is that it's virtually impossible to
 * provide a fork-safe library when you have native threads you don't own
 * running around. If you fork when a thread holds a mutex, and that thread
 * is not the fork-caller, that mutex can never be unlocked, and is therefore
 * a ticking time-bomb in the child. The only way to guarantee safety is to
 * either replace all of your mutexes and conditions and such after a fork
 * (which is what we do on the ruby side), or avoid the problem altogether
 * and not use a multithreaded library on the backend. Since we can't replace
 * mutexes in the zookeeper code, we opt for the latter solution.
 *
 * The ruby code runs the event loop in a thread that will never cause a fork()
 * to occur. This way, when fork() is called, the event thread will be dead
 * in the child, guaranteeing that the child can safely be cleaned up.
 *
 * In that cleanup, there is a nasty (and brutishly effective) hack that makes
 * the fork case work. We keep track of the pid that allocated the
 * zkrb_instance_data_t, and if at destruction time we see that a fork has
 * happened, we reach inside the zookeeper handle (zk->zh), and close the
 * open socket it's got before calling zookeeper_close. This prevents
 * corruption of the client/server state. Without this code, zookeeper_close
 * in the child would actually send an "Ok, we're closing" message with the
 * parent's session id, causing the parent to hit an assert() case in
 * zookeeper_process, and cause a SIGABRT. With this code in place, we get back
 * a ZCONNECTIONLOSS from zookeeper_close in the child (which we ignore), and
 * the parent continues on.
 *
 * You will notice below we undef 'THREADED', which would be set if we were
 * using the 'mt' library. We also conditionally include additional cases
 * ('SYNC', 'SYNC_WATCH') inside of some of the methods defined here. These
 * would be valid when running the 'mt' library, but since we have a ruby layer
 * to provide a sync front-end to an async backend, these cases should never be
 * hit, and instead will raise exceptions.
 *
 * NOTE: This file depends on exception classes defined in lib/zookeeper/exceptions.rb
 *
 * -------
 *
 * @rectalogic: any time you create a ruby value in C, and so there are no
 * references to it in the VM except for your variable, and you then call into
 * the VM (allowing a GC), and your reference is on the stack, then it needs to
 * be volatile
 *
 */

#include "ruby.h"

#ifdef ZKRB_RUBY_187
#include "rubyio.h"
#else
#include "ruby/io.h"
#endif

#include "zookeeper/zookeeper.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/fcntl.h>
#include <pthread.h>
#include <inttypes.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#include "common.h"
#include "event_lib.h"
#include "zkrb_wrapper.h"
#include "dbg.h"

static VALUE mZookeeper = Qnil;         // the Zookeeper module
static VALUE CZookeeper = Qnil;         // the Zookeeper::CZookeeper class
static VALUE ZookeeperClientId = Qnil;
static VALUE mZookeeperExceptions = Qnil;    // the Zookeeper::Exceptions module
static VALUE eHandleClosedException = Qnil;  // raised when we don't have a valid handle in FETCH_DATA_PTR

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

inline static const char* call_type_to_str(zkrb_call_type ct) {
  const char *rv = NULL;
  switch (ct) {
    case SYNC:
      rv="SYNC";
      break;
    case ASYNC:
      rv="ASYNC";
      break;
    case SYNC_WATCH:
      rv="SYNC_WATCH";
      break;
    case ASYNC_WATCH:
      rv="ASYNC_WATCH";
      break;
  }
  return rv;
}

inline static void assert_valid_params(VALUE reqid, VALUE path) {
  switch (TYPE(reqid)) {
    case T_FIXNUM:
    case T_BIGNUM:
      break;
    default:
      rb_raise(rb_eTypeError, "reqid must be Fixnum/Bignum");
  }

  Check_Type(path, T_STRING);
}

inline static zkrb_call_type get_call_type(VALUE async, VALUE watch) {
  if (RTEST(async)) {
    return RTEST(watch) ? ASYNC_WATCH : ASYNC;
  } else {
    return RTEST(watch) ? SYNC_WATCH : SYNC;
  }
}

inline static void raise_invalid_call_type_err(zkrb_call_type call_type) {
  rb_raise(rb_eRuntimeError, "hit the default case, call_type: %s", call_type_to_str(call_type));
}

#define IS_SYNC(zkrbcall) ((zkrbcall)==SYNC || (zkrbcall)==SYNC_WATCH)
#define IS_ASYNC(zkrbcall) ((zkrbcall)==ASYNC || (zkrbcall)==ASYNC_WATCH)

#define FETCH_DATA_PTR(SELF, ZK)                                        \
  zkrb_instance_data_t * ZK;                                            \
  Data_Get_Struct(rb_iv_get(SELF, "@_data"), zkrb_instance_data_t, ZK); \
  if ((ZK)->zh == NULL)                                                 \
    rb_raise(eHandleClosedException, "zookeeper handle is closed")

#define STANDARD_PREAMBLE(SELF, ZK, REQID, PATH, ASYNC, WATCH, CALL_TYPE) \
  assert_valid_params(REQID, PATH); \
  FETCH_DATA_PTR(SELF, ZK); \
  zkrb_call_type CALL_TYPE = get_call_type(ASYNC, WATCH); \

#define CTX_ALLOC(ZK,REQID) zkrb_calling_context_alloc(NUM2LL(REQID), ZK->queue)

static void hexbufify(char *dest, const char *src, int len) {
  int i=0;

  for (i=0; i < len; i++) {
    sprintf(&dest[i*2], "%x", src[i]);
  }
}

inline static int we_are_forked(zkrb_instance_data_t *zk) {
  int rv=0;

  if ((!!zk) && (zk->orig_pid != getpid())) {
    rv=1;
  }

  return rv;
}


static int destroy_zkrb_instance(zkrb_instance_data_t* zk) {
  int rv = ZOK;

  zkrb_debug("destroy_zkrb_instance, zk_local_ctx: %p, zh: %p, queue: %p", zk, zk->zh, zk->queue);

  if (zk->zh) {
    const void *ctx = zoo_get_context(zk->zh);
    /* Note that after zookeeper_close() returns, ZK handle is invalid */
    zkrb_debug("obj_id: %lx, calling zookeeper_close", zk->object_id);

    if (we_are_forked(zk)) {
      zkrb_debug("FORK DETECTED! orig_pid: %d, current pid: %d, "
          "using socket-closing hack before zookeeper_close", zk->orig_pid, getpid());

      int fd = ((int *)zk->zh)[0];  // nasty, brutish, and wonderfully effective hack (see above)
      close(fd);

    }

    rv = zookeeper_close(zk->zh);

    zkrb_debug("obj_id: %lx, zookeeper_close returned %d, calling context: %p", zk->object_id, rv, ctx);
    zkrb_calling_context_free((zkrb_calling_context *) ctx);
  }

  zk->zh = NULL;

  if (zk->queue) {
    zkrb_debug("obj_id: %lx, freeing queue pointer: %p", zk->object_id, zk->queue);
    zkrb_queue_free(zk->queue);
  }

  zk->queue = NULL;

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

#define receive_timeout_msec(self) rb_iv_get(self, "@_receive_timeout_msec")

inline static void zkrb_debug_clientid_t(const clientid_t *cid) {
  int pass_len = sizeof(cid->passwd);
  int hex_len = 2 * pass_len + 1;
  char buf[hex_len];
  hexbufify(buf, cid->passwd, pass_len);

  zkrb_debug("myid, client_id: %"PRId64", passwd: %*s", cid->client_id, hex_len, buf);
}

static VALUE method_zkrb_init(int argc, VALUE* argv, VALUE self) {
  VALUE hostPort=Qnil;
  VALUE options=Qnil;

  rb_scan_args(argc, argv, "11", &hostPort, &options);

  if (NIL_P(options)) {
    options = rb_hash_new();
  } else {
    Check_Type(options, T_HASH);
  }

  Check_Type(hostPort, T_STRING);

  // Look up :zkc_log_level
  // VALUE log_level = rb_hash_aref(options, ID2SYM(rb_intern("zkc_log_level")));
  // if (NIL_P(log_level)) {
  //   zoo_set_debug_level(0); // no log messages
  // } else {
  //   Check_Type(log_level, T_FIXNUM);
  //   zoo_set_debug_level(FIX2INT(log_level));
  // }

  volatile VALUE data;
  zkrb_instance_data_t *zk_local_ctx;
  data = Data_Make_Struct(CZookeeper, zkrb_instance_data_t, 0, free_zkrb_instance_data, zk_local_ctx);

  // Look up :session_id and :session_passwd
  VALUE session_id = rb_hash_aref(options, ID2SYM(rb_intern("session_id")));
  VALUE password   = rb_hash_aref(options, ID2SYM(rb_intern("session_passwd")));
  if (!NIL_P(session_id) && !NIL_P(password)) {
      Check_Type(password, T_STRING);

      zk_local_ctx->myid.client_id = NUM2LL(session_id);
      strncpy(zk_local_ctx->myid.passwd, RSTRING_PTR(password), 16);
  }

  zk_local_ctx->queue = zkrb_queue_alloc();

  if (zk_local_ctx->queue == NULL)
    rb_raise(rb_eRuntimeError, "could not allocate zkrb queue!");

  zoo_deterministic_conn_order(0);

  zkrb_calling_context *ctx =
    zkrb_calling_context_alloc(ZKRB_GLOBAL_REQ, zk_local_ctx->queue);

  zk_local_ctx->object_id = FIX2LONG(rb_obj_id(self));

  zk_local_ctx->zh =
      zookeeper_init(
          RSTRING_PTR(hostPort),        // const char *host
          zkrb_state_callback,          // watcher_fn
          receive_timeout_msec(self),   // recv_timeout
          &zk_local_ctx->myid,          // cilentid_t
          ctx,                          // void *context
          0);                           // flags

  zkrb_debug("method_zkrb_init, zk_local_ctx: %p, zh: %p, queue: %p, calling_ctx: %p",
      zk_local_ctx, zk_local_ctx->zh, zk_local_ctx->queue, ctx);

  if (!zk_local_ctx->zh) {
    rb_raise(rb_eRuntimeError, "error connecting to zookeeper: %d", errno);
  }

  zk_local_ctx->orig_pid = getpid();

  rb_iv_set(self, "@_data", data);
  rb_funcall(self, rb_intern("zkc_set_running_and_notify!"), 0);

  return Qnil;
}

static VALUE method_get_children(VALUE self, VALUE reqid, VALUE path, VALUE async, VALUE watch) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, call_type);

  VALUE output = Qnil;
  struct String_vector strings;
  struct Stat stat;

  int rc = 0;
  switch (call_type) {

#ifdef THREADED
    case SYNC:
      rc = zkrb_call_zoo_get_children2(
              zk->zh, RSTRING_PTR(path), 0, &strings, &stat);
      break;

    case SYNC_WATCH:
      rc = zkrb_call_zoo_wget_children2(
              zk->zh, RSTRING_PTR(path), zkrb_state_callback, CTX_ALLOC(zk, reqid), &strings, &stat);
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_aget_children2(
              zk->zh, RSTRING_PTR(path), 0, zkrb_strings_stat_callback, CTX_ALLOC(zk, reqid));
      break;

    case ASYNC_WATCH:
      rc = zkrb_call_zoo_awget_children2(
              zk->zh, RSTRING_PTR(path), zkrb_state_callback, CTX_ALLOC(zk, reqid), zkrb_strings_stat_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      raise_invalid_call_type_err(call_type);
      break;
  }

  output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_string_vector_to_ruby(&strings));
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  return output;
}

static VALUE method_exists(VALUE self, VALUE reqid, VALUE path, VALUE async, VALUE watch) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, call_type);

  VALUE output = Qnil;
  struct Stat stat;

  int rc = 0;
  switch (call_type) {

#ifdef THREADED
    case SYNC:
      rc = zkrb_call_zoo_exists(zk->zh, RSTRING_PTR(path), 0, &stat);
      break;

    case SYNC_WATCH:
      rc = zkrb_call_zoo_wexists(zk->zh, RSTRING_PTR(path), zkrb_state_callback, CTX_ALLOC(zk, reqid), &stat);
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_aexists(zk->zh, RSTRING_PTR(path), 0, zkrb_stat_callback, CTX_ALLOC(zk, reqid));
      break;

    case ASYNC_WATCH:
      rc = zkrb_call_zoo_awexists(zk->zh, RSTRING_PTR(path), zkrb_state_callback, CTX_ALLOC(zk, reqid), zkrb_stat_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      raise_invalid_call_type_err(call_type);
      break;
  }

  output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  return output;
}

// this method is *only* called asynchronously
static VALUE method_sync(VALUE self, VALUE reqid, VALUE path) {
  int rc = ZOK;

  // don't use STANDARD_PREAMBLE here b/c we don't need to determine call_type
  assert_valid_params(reqid, path);
  FETCH_DATA_PTR(self, zk);

  rc = zkrb_call_zoo_async(zk->zh, RSTRING_PTR(path), zkrb_string_callback, CTX_ALLOC(zk, reqid));

  return INT2FIX(rc);
}

static VALUE method_add_auth(VALUE self, VALUE reqid, VALUE scheme, VALUE cert) {
  int rc = ZOK;

  Check_Type(scheme, T_STRING);
  Check_Type(cert, T_STRING);

  FETCH_DATA_PTR(self, zk);

  rc = zkrb_call_zoo_add_auth(zk->zh, RSTRING_PTR(scheme), RSTRING_PTR(cert), RSTRING_LEN(cert), zkrb_void_callback, CTX_ALLOC(zk, reqid));

  return INT2FIX(rc);
}


static VALUE method_create(VALUE self, VALUE reqid, VALUE path, VALUE data, VALUE async, VALUE acls, VALUE flags) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, Qfalse, call_type);
  VALUE output = Qnil;

  if (data != Qnil) Check_Type(data, T_STRING);
  Check_Type(flags, T_FIXNUM);
  const char *data_ptr = (data == Qnil) ? NULL : RSTRING_PTR(data);
  ssize_t     data_len = (data == Qnil) ? -1   : RSTRING_LEN(data);

  struct ACL_vector *aclptr = NULL;
  if (acls != Qnil) { aclptr = zkrb_ruby_to_aclvector(acls); }
  char realpath[16384];

  int invalid_call_type=0;

  int rc = 0;
  switch (call_type) {

#ifdef THREADED
    case SYNC:
      // casting data_len to int is OK as you can only store 1MB in zookeeper
      rc = zkrb_call_zoo_create(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, aclptr, FIX2INT(flags), realpath, sizeof(realpath));
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_acreate(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, aclptr, FIX2INT(flags), zkrb_string_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      invalid_call_type=1;
      break;
  }

  if (aclptr) {
    deallocate_ACL_vector(aclptr);
    free(aclptr);
  }

  if (invalid_call_type) raise_invalid_call_type_err(call_type);

  output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    return rb_ary_push(output, rb_str_new2(realpath));
  }
  return output;
}

static VALUE method_delete(VALUE self, VALUE reqid, VALUE path, VALUE version, VALUE async) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, Qfalse, call_type);
  Check_Type(version, T_FIXNUM);

  int rc = 0;
  switch (call_type) {

#ifdef THREADED
    case SYNC:
      rc = zkrb_call_zoo_delete(zk->zh, RSTRING_PTR(path), FIX2INT(version));
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_adelete(zk->zh, RSTRING_PTR(path), FIX2INT(version), zkrb_void_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      raise_invalid_call_type_err(call_type);
      break;
  }

  return INT2FIX(rc);
}

#define MAX_ZNODE_SIZE 1048576

static VALUE method_get(VALUE self, VALUE reqid, VALUE path, VALUE async, VALUE watch) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, watch, call_type);

  VALUE output = Qnil;

  int data_len = MAX_ZNODE_SIZE;
  struct Stat stat;

  char * data = NULL;
  if (IS_SYNC(call_type)) {
    data = malloc(MAX_ZNODE_SIZE); /* ugh */
    memset(data, 0, MAX_ZNODE_SIZE);
  }

  int rc, invalid_call_type=0;

  switch (call_type) {

#ifdef THREADED
    case SYNC:
      rc = zkrb_call_zoo_get(zk->zh, RSTRING_PTR(path), 0, data, &data_len, &stat);
      break;

    case SYNC_WATCH:
      rc = zkrb_call_zoo_wget(
              zk->zh, RSTRING_PTR(path), zkrb_state_callback, CTX_ALLOC(zk, reqid), data, &data_len, &stat);
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_aget(zk->zh, RSTRING_PTR(path), 0, zkrb_data_callback, CTX_ALLOC(zk, reqid));
      break;

    case ASYNC_WATCH:
      // first ctx is a watch, second is the async callback
      rc = zkrb_call_zoo_awget(
            zk->zh, RSTRING_PTR(path), zkrb_state_callback, CTX_ALLOC(zk, reqid), zkrb_data_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      invalid_call_type=1;
      goto cleanup;
      break;
  }

  output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    if (data_len == -1)
      rb_ary_push(output, Qnil);        /* No data associated with path */
    else
      rb_ary_push(output, rb_str_new(data, data_len));
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }

cleanup:
  free(data);
  if (invalid_call_type) raise_invalid_call_type_err(call_type);
  return output;
}

static VALUE method_set(VALUE self, VALUE reqid, VALUE path, VALUE data, VALUE async, VALUE version) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, Qfalse, call_type);

  VALUE output = Qnil;
  struct Stat stat;

  if (data != Qnil) Check_Type(data, T_STRING);

  const char *data_ptr = (data == Qnil) ? NULL : RSTRING_PTR(data);
  ssize_t     data_len = (data == Qnil) ? -1   : RSTRING_LEN(data);

  int rc=ZOK;
  switch (call_type) {

#ifdef THREADED
    case SYNC:
      rc = zkrb_call_zoo_set2(zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, FIX2INT(version), &stat);
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_aset(
            zk->zh, RSTRING_PTR(path), data_ptr, (int)data_len, FIX2INT(version), zkrb_stat_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      raise_invalid_call_type_err(call_type);
      break;
  }

  output = rb_ary_new();
  rb_ary_push(output, INT2FIX(rc));
  if (IS_SYNC(call_type) && rc == ZOK) {
    rb_ary_push(output, zkrb_stat_to_rarray(&stat));
  }
  return output;
}

static VALUE method_set_acl(VALUE self, VALUE reqid, VALUE path, VALUE acls, VALUE async, VALUE version) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, Qfalse, call_type);

  struct ACL_vector * aclptr = zkrb_ruby_to_aclvector(acls);

  int rc=ZOK, invalid_call_type=0;
  switch (call_type) {

#ifdef THREADED
    case SYNC:
      rc = zkrb_call_zoo_set_acl(zk->zh, RSTRING_PTR(path), FIX2INT(version), aclptr);
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_aset_acl(zk->zh, RSTRING_PTR(path), FIX2INT(version), aclptr, zkrb_void_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      invalid_call_type=1;
      break;
  }

  deallocate_ACL_vector(aclptr);
  free(aclptr);

  if (invalid_call_type) raise_invalid_call_type_err(call_type);

  return INT2FIX(rc);
}

static VALUE method_get_acl(VALUE self, VALUE reqid, VALUE path, VALUE async) {
  STANDARD_PREAMBLE(self, zk, reqid, path, async, Qfalse, call_type);

  VALUE output = Qnil;
  struct ACL_vector acls;
  struct Stat stat;

  int rc=ZOK;
  switch (call_type) {

#ifdef THREADED
    case SYNC:
      rc = zkrb_call_zoo_get_acl(zk->zh, RSTRING_PTR(path), &acls, &stat);
      break;
#endif

    case ASYNC:
      rc = zkrb_call_zoo_aget_acl(zk->zh, RSTRING_PTR(path), zkrb_acl_callback, CTX_ALLOC(zk, reqid));
      break;

    default:
      raise_invalid_call_type_err(call_type);
      break;
  }

  output = rb_ary_new();
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
  volatile VALUE rval = Qnil;

  if (is_closed(self)) {
    zkrb_debug("we are closed, not gonna try to get an event");
    return Qnil;
  }

  FETCH_DATA_PTR(self, zk);

  zkrb_event_t *event = zkrb_dequeue(zk->queue, 0);

  if (event != NULL) {
    rval = zkrb_event_to_ruby(event);
    zkrb_event_free(event);

#if THREADED
    int fd = zk->queue->pipe_read;

    // we don't care in this case. this is just until i can remove the self
    // pipe from the queue
    char b[128];
    while(read(fd, b, sizeof(b)) == sizeof(b)){}
#endif
  }

  return rval;
}

inline static int get_self_pipe_read_fd(VALUE self) {
  rb_io_t *fptr;
  VALUE pipe_read = rb_iv_get(self, "@pipe_read");

  if (NIL_P(pipe_read))
      rb_raise(rb_eRuntimeError, "@pipe_read was nil!");

  GetOpenFile(pipe_read, fptr);

  rb_io_check_readable(fptr);

#ifdef ZKRB_RUBY_187
  return fileno(fptr->f);
#else
  return fptr->fd;
#endif
}

static VALUE method_zkrb_iterate_event_loop(VALUE self) {
  FETCH_DATA_PTR(self, zk);

  fd_set rfds, wfds, efds;
  FD_ZERO(&rfds); FD_ZERO(&wfds); FD_ZERO(&efds);

  int fd = 0, interest = 0, events = 0, rc = 0, maxfd = 0, irc = 0, prc = 0;
  struct timeval tv;

  irc = zookeeper_interest(zk->zh, &fd, &interest, &tv);

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

  // add our self-pipe to the read set, allow us to wake up in case our attention is needed
  int pipe_r_fd = get_self_pipe_read_fd(self);

  FD_SET(pipe_r_fd, &rfds);

  maxfd = (pipe_r_fd > fd) ? pipe_r_fd : fd;

  rc = rb_thread_select(maxfd+1, &rfds, &wfds, &efds, &tv);

  if (rc > 0) {
    if (FD_ISSET(fd, &rfds)) {
      events |= ZOOKEEPER_READ;
    }
    if (FD_ISSET(fd, &wfds)) {
      events |= ZOOKEEPER_WRITE;
    }

    // we got woken up by the self-pipe
    if (FD_ISSET(pipe_r_fd, &rfds)) {
      // one event has awoken us, so we clear one event from the pipe
      char b[1];

      if (read(pipe_r_fd, b, 1) < 0) {
        rb_raise(rb_eRuntimeError, "read from pipe failed: %s", clean_errno());
      }
    }
  }
  else if (rc == 0) {
    // zkrb_debug("timed out waiting for descriptor to be ready. interest=%d fd=%d pipe_r_fd=%d maxfd=%d irc=%d timeout=%f",
    //   interest, fd, pipe_r_fd, maxfd, irc, tv.tv_sec + (tv.tv_usec/ 1000.0 / 1000.0));
  }
  else {
    log_err("select returned an error: rc=%d interest=%d fd=%d pipe_r_fd=%d maxfd=%d irc=%d timeout=%f",
      rc, interest, fd, pipe_r_fd, maxfd, irc, tv.tv_sec + (tv.tv_usec/ 1000.0 / 1000.0));
  }

  prc = zookeeper_process(zk->zh, events);

  if (rc == 0) {
    zkrb_debug("timed out waiting for descriptor to be ready. prc=%d interest=%d fd=%d pipe_r_fd=%d maxfd=%d irc=%d timeout=%f",
      prc, interest, fd, pipe_r_fd, maxfd, irc, tv.tv_sec + (tv.tv_usec/ 1000.0 / 1000.0));
  }

  return INT2FIX(prc);
}

static VALUE method_has_events(VALUE self) {
  VALUE rb_event;
  FETCH_DATA_PTR(self, zk);

  rb_event = zkrb_peek(zk->queue) != NULL ? Qtrue : Qfalse;
  return rb_event;
}

static VALUE method_zoo_set_log_level(VALUE self, VALUE level) {
  Check_Type(level, T_FIXNUM);
  zoo_set_debug_level(FIX2INT(level));
  return Qnil;
}

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

// returns a CZookeeper::ClientId object with the values set for session_id and passwd
static VALUE method_client_id(VALUE self) {
  FETCH_DATA_PTR(self, zk);
  const clientid_t *cid = zoo_client_id(zk->zh);

  VALUE session_id = LL2NUM(cid->client_id);
  VALUE passwd = rb_str_new(cid->passwd, 16);

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

static VALUE method_connected_host(VALUE self) {
  FETCH_DATA_PTR(self, zk);

  struct sockaddr addr;
  socklen_t addr_len = sizeof(addr);

  if (zookeeper_get_connected_host(zk->zh, &addr, &addr_len) != NULL) {
    char buf[255];
    char addrstr[128];
    void *inaddr;
    int port;

#if defined(AF_INET6)
    if(addr.sa_family==AF_INET6){
        inaddr = &((struct sockaddr_in6 *) &addr)->sin6_addr;
        port = ((struct sockaddr_in6 *) &addr)->sin6_port;
    } else {
#endif
      inaddr = &((struct sockaddr_in *) &addr)->sin_addr;
      port = ((struct sockaddr_in *) &addr)->sin_port;
#if defined(AF_INET6)
    }
#endif

    inet_ntop(addr.sa_family, inaddr, addrstr, sizeof(addrstr)-1);
    snprintf(buf, sizeof(buf), "%s:%d", addrstr, ntohs(port));
    return rb_str_new2(buf);
  }

  return Qnil;
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
  rb_define_method(CZookeeper, "zkrb_add_auth",     method_add_auth,      3);

  rb_define_singleton_method(CZookeeper, "zoo_set_log_level", method_zoo_set_log_level, 1);

  DEFINE_METHOD(client_id, 0);
  DEFINE_METHOD(close_handle, 0);
  DEFINE_METHOD(deterministic_conn_order, 1);
  DEFINE_METHOD(is_unrecoverable, 0);
  DEFINE_METHOD(recv_timeout, 1);
  DEFINE_METHOD(zkrb_state, 0);
  DEFINE_METHOD(sync, 2);
  DEFINE_METHOD(zkrb_iterate_event_loop, 0);
  DEFINE_METHOD(zkrb_get_next_event_st, 0);
  DEFINE_METHOD(connected_host, 0);

  // methods for the ruby-side event manager
  DEFINE_METHOD(zkrb_get_next_event, 1);
  DEFINE_METHOD(zkrb_get_next_event_st, 0);
  DEFINE_METHOD(has_events, 0);

  // Make these class methods?
  DEFINE_METHOD(zerror, 1);

  rb_define_singleton_method(CZookeeper, "set_zkrb_debug_level", klass_method_zkrb_set_debug_level, 1);

  rb_attr(CZookeeper, rb_intern("selectable_io"), 1, 0, Qtrue);

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
  // Don't debug by default
  ZKRBDebugging = 0;
  zoo_set_debug_level(0);

  mZookeeper = rb_define_module("Zookeeper");
  mZookeeperExceptions = rb_define_module_under(mZookeeper, "Exceptions");

  // this will likely fail if the load order is screwed up
  eHandleClosedException = rb_const_get(mZookeeperExceptions, rb_intern("HandleClosedException"));

  /* initialize CZookeeper class */
  CZookeeper = rb_define_class_under(mZookeeper, "CZookeeper", rb_cObject);
  zkrb_define_methods();

  ZookeeperClientId = rb_define_class_under(CZookeeper, "ClientId", rb_cObject);
  rb_define_method(ZookeeperClientId, "initialize", zkrb_client_id_method_initialize, 0);
  rb_define_attr(ZookeeperClientId, "session_id", 1, 1);
  rb_define_attr(ZookeeperClientId, "passwd", 1, 1);

}

// vim:ts=2:sw=2:sts=2:et
