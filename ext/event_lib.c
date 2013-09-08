/* Ruby wrapper for the Zookeeper C API

This file contains three sets of helpers:
  - the event queue that glues RB<->C together
  - the completions that marshall data between RB<->C formats
  - functions for translating between Ruby and C versions of ZK datatypes

wickman@twitter.com


NOTE: be *very careful* in these functions, calling *ANY* ruby interpreter
function when you're not in an interpreter thread can hork ruby, trigger a
[BUG], corrupt the stack, kill your dog, knock up your daughter, etc. etc.

NOTE: the above is only true when you're running in THREADED mode, in 
single-threaded, everything is called on an interpreter thread.


slyphon@gmail.com

*/

#include "ruby.h"
#include "zookeeper/zookeeper.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <inttypes.h>
#include "common.h"
#include "event_lib.h"
#include "dbg.h"

#ifndef THREADED
#define USE_XMALLOC
#endif

#define GET_SYM(str) ID2SYM(rb_intern(str))

int ZKRBDebugging;

#if THREADED
pthread_mutex_t zkrb_q_mutex = PTHREAD_MUTEX_INITIALIZER;
#endif

inline static int global_mutex_lock() {
  int rv=0;
#if THREADED
  rv = pthread_mutex_lock(&zkrb_q_mutex);
  if (rv != 0) log_err("global_mutex_lock error");
#endif
  return rv;
}

inline static int global_mutex_unlock() {
  int rv=0;
#if THREADED
  rv = pthread_mutex_unlock(&zkrb_q_mutex);
  if (rv != 0) log_err("global_mutex_unlock error");
#endif
  return rv;
}

// we can use the ruby xmalloc/xfree that will raise errors
// in the case of a failure to allocate memory, and can cycle
// the garbage collector in some cases.

inline static void* zk_malloc(size_t size) {
#ifdef USE_XMALLOC
  return xmalloc(size);
#else
  return malloc(size);
#endif
}

inline static void zk_free(void *ptr) {
#ifdef USE_XMALLOC
  xfree(ptr);
#else
  free(ptr);
#endif
}

void zkrb_enqueue(zkrb_queue_t *q, zkrb_event_t *elt) {
  if (q == NULL) {
    zkrb_debug("zkrb_enqueue, queue ptr was NULL");
    return;
  }

  if (q->tail == NULL) {
    zkrb_debug("zkrb_enqeue, q->tail was NULL");
    return;
  }

  global_mutex_lock();

  q->tail->event = elt;
  q->tail->next = (zkrb_event_ll_t *)zk_malloc(sizeof(zkrb_event_ll_t));
  q->tail = q->tail->next;
  q->tail->event = NULL;
  q->tail->next = NULL;

  global_mutex_unlock();

#if THREADED
  ssize_t ret = write(q->pipe_write, "0", 1);   /* Wake up Ruby listener */

  if (ret < 0)
    log_err("write to queue (%p) pipe failed!\n", q);
#endif

}

// NOTE: the zkrb_event_t* returned *is* the same pointer that's part of the
// queue, the only place this is used is in method_has_events, and it is simply
// tested for null-ness. it's probably better to make the null-test here and
// not return the pointer
//
zkrb_event_t * zkrb_peek(zkrb_queue_t *q) {
  zkrb_event_t *event = NULL;

  if (!q) return NULL;

  global_mutex_lock();

  if (q != NULL && q->head != NULL && q->head->event != NULL) {
    event = q->head->event;
  }

  global_mutex_unlock();

  return event;
}

#define ZKRB_QUEUE_EMPTY(q) (q == NULL || q->head == NULL || q->head->event == NULL)

zkrb_event_t* zkrb_dequeue(zkrb_queue_t *q, int need_lock) {
  zkrb_event_t *rv = NULL;
  zkrb_event_ll_t *old_root = NULL;
    
  if (need_lock)
    global_mutex_lock();

  if (!ZKRB_QUEUE_EMPTY(q)) {
    old_root = q->head;
    q->head = q->head->next;
    rv = old_root->event;
  }

  if (need_lock)
    global_mutex_unlock();

  zk_free(old_root);
  return rv;
}

void zkrb_signal(zkrb_queue_t *q) {
  if (!q) return;

  global_mutex_lock();

#if THREADED
  if (!write(q->pipe_write, "0", 1))      /* Wake up Ruby listener */
    log_err("zkrb_signal: write to pipe failed, could not wake");
#endif

  global_mutex_unlock();
}

zkrb_event_ll_t *zkrb_event_ll_t_alloc(void) {
  zkrb_event_ll_t *rv = zk_malloc(sizeof(zkrb_event_ll_t));

  if (!rv) return NULL;

  rv->event = NULL;
  rv->next = NULL;

  return rv;
}

zkrb_queue_t *zkrb_queue_alloc(void) {
  zkrb_queue_t *rq = NULL;
 
#if THREADED
  int pfd[2];
  check(pipe(pfd) == 0, "creating the signal pipe failed");
#endif

  rq = zk_malloc(sizeof(zkrb_queue_t));
  check_mem(rq);

  rq->orig_pid = getpid();

  rq->head = zkrb_event_ll_t_alloc();
  check_mem(rq->head);

  rq->tail = rq->head;

#if THREADED
  rq->pipe_read = pfd[0];
  rq->pipe_write = pfd[1];
#endif

  return rq;

error:
  zk_free(rq);
  return NULL;
}

void zkrb_queue_free(zkrb_queue_t *queue) {
  if (!queue) return;

  zkrb_event_t *elt;
  while ((elt = zkrb_dequeue(queue, 0)) != NULL) {
    zkrb_event_free(elt);
  }

  zk_free(queue->head);

#if THREADED
  close(queue->pipe_read);
  close(queue->pipe_write);
#endif

  zk_free(queue);
}

zkrb_event_t *zkrb_event_alloc(void) {
  zkrb_event_t *rv = zk_malloc(sizeof(zkrb_event_t));
  return rv;
}

void zkrb_event_free(zkrb_event_t *event) {
  switch (event->type) {
    case ZKRB_DATA: {
      struct zkrb_data_completion *data_ctx = event->completion.data_completion;
      zk_free(data_ctx->data);
      zk_free(data_ctx->stat);
      zk_free(data_ctx);
      break;
    }
    case ZKRB_STAT: {
      struct zkrb_stat_completion *stat_ctx = event->completion.stat_completion;
      zk_free(stat_ctx->stat);
      zk_free(stat_ctx);
      break;
    }
    case ZKRB_STRING: {
      struct zkrb_string_completion *string_ctx = event->completion.string_completion;
      zk_free(string_ctx->value);
      zk_free(string_ctx);
      break;
    }
    case ZKRB_STRINGS: {
      struct zkrb_strings_completion *strings_ctx = event->completion.strings_completion;
      int k;
      if (strings_ctx->values) {
        for (k = 0; k < strings_ctx->values->count; ++k) {
          zk_free(strings_ctx->values->data[k]);
        }
        zk_free(strings_ctx->values);
      }
      zk_free(strings_ctx);
      break;
    }
    case ZKRB_STRINGS_STAT: {
      struct zkrb_strings_stat_completion *strings_stat_ctx = event->completion.strings_stat_completion;
      int k;
      if (strings_stat_ctx->values) {
        for (k = 0; k < strings_stat_ctx->values->count; ++k) {
          zk_free(strings_stat_ctx->values->data[k]);
        }
        zk_free(strings_stat_ctx->values);
      }

      if (strings_stat_ctx->stat) zk_free(strings_stat_ctx->stat);
      zk_free(strings_stat_ctx);
      break;
    }
    case ZKRB_ACL: {
      struct zkrb_acl_completion *acl_ctx = event->completion.acl_completion;
      if (acl_ctx->acl) {
        deallocate_ACL_vector(acl_ctx->acl);
        zk_free(acl_ctx->acl);
      }
      zk_free(acl_ctx->stat);
      zk_free(acl_ctx);
      break;
    }
    case ZKRB_WATCHER: {
      struct zkrb_watcher_completion *watcher_ctx = event->completion.watcher_completion;
      zk_free(watcher_ctx->path);
      zk_free(watcher_ctx);
      break;
    }
    case ZKRB_VOID: {
      break;
    }
    default:
      log_err("unrecognized event in event_free!");
  }

  zk_free(event);
}

/* this is called only from a method_get_latest_event, so the hash is
   allocated on the proper thread stack */
VALUE zkrb_event_to_ruby(zkrb_event_t *event) {
  VALUE hash = rb_hash_new();

  if (!event) {
    log_err("event was NULL in zkrb_event_to_ruby");
    return hash;
  }

  rb_hash_aset(hash, GET_SYM("req_id"), LL2NUM(event->req_id));
  if (event->type != ZKRB_WATCHER)
    rb_hash_aset(hash, GET_SYM("rc"), INT2FIX(event->rc));

  switch (event->type) {
    case ZKRB_DATA: {
      zkrb_debug("zkrb_event_to_ruby ZKRB_DATA");
      struct zkrb_data_completion *data_ctx = event->completion.data_completion;
      if (ZKRBDebugging) zkrb_print_stat(data_ctx->stat);
      rb_hash_aset(hash, GET_SYM("data"), data_ctx->data ? rb_str_new(data_ctx->data, data_ctx->data_len) : Qnil);
      rb_hash_aset(hash, GET_SYM("stat"), data_ctx->stat ? zkrb_stat_to_rarray(data_ctx->stat) : Qnil);
      break;
    }
    case ZKRB_STAT: {
      zkrb_debug("zkrb_event_to_ruby ZKRB_STAT");
      struct zkrb_stat_completion *stat_ctx = event->completion.stat_completion;
      rb_hash_aset(hash, GET_SYM("stat"), stat_ctx->stat ? zkrb_stat_to_rarray(stat_ctx->stat) : Qnil);
      break;
    }
    case ZKRB_STRING: {
      zkrb_debug("zkrb_event_to_ruby ZKRB_STRING");
      struct zkrb_string_completion *string_ctx = event->completion.string_completion;
      rb_hash_aset(hash, GET_SYM("string"), string_ctx->value ? rb_str_new2(string_ctx->value) : Qnil);
      break;
    }
    case ZKRB_STRINGS: {
      zkrb_debug("zkrb_event_to_ruby ZKRB_STRINGS");
      struct zkrb_strings_completion *strings_ctx = event->completion.strings_completion;
      rb_hash_aset(hash, GET_SYM("strings"), strings_ctx->values ? zkrb_string_vector_to_ruby(strings_ctx->values) : Qnil);
      break;
    }
    case ZKRB_STRINGS_STAT: {
      zkrb_debug("zkrb_event_to_ruby ZKRB_STRINGS_STAT");
      struct zkrb_strings_stat_completion *strings_stat_ctx = event->completion.strings_stat_completion;
      rb_hash_aset(hash, GET_SYM("strings"), strings_stat_ctx->values ? zkrb_string_vector_to_ruby(strings_stat_ctx->values) : Qnil);
      rb_hash_aset(hash, GET_SYM("stat"), strings_stat_ctx->stat ? zkrb_stat_to_rarray(strings_stat_ctx->stat) : Qnil);
      break;
    }
    case ZKRB_ACL: {
      zkrb_debug("zkrb_event_to_ruby ZKRB_ACL");
      struct zkrb_acl_completion *acl_ctx = event->completion.acl_completion;
      rb_hash_aset(hash, GET_SYM("acl"), acl_ctx->acl ? zkrb_acl_vector_to_ruby(acl_ctx->acl) : Qnil);
      rb_hash_aset(hash, GET_SYM("stat"), acl_ctx->stat ? zkrb_stat_to_rarray(acl_ctx->stat) : Qnil);
      break;
    }
    case ZKRB_WATCHER: {
      zkrb_debug("zkrb_event_to_ruby ZKRB_WATCHER");
      struct zkrb_watcher_completion *watcher_ctx = event->completion.watcher_completion;
      rb_hash_aset(hash, GET_SYM("type"), INT2FIX(watcher_ctx->type));
      rb_hash_aset(hash, GET_SYM("state"), INT2FIX(watcher_ctx->state));
      rb_hash_aset(hash, GET_SYM("path"), watcher_ctx->path ? rb_str_new2(watcher_ctx->path) : Qnil);
      break;
    }
    case ZKRB_VOID:
    default:
      break;
  }

  return hash;
}

void zkrb_print_stat(const struct Stat *s) {
  if (s != NULL) {
    fprintf(stderr,  "stat {\n");
    fprintf(stderr,  "\t          czxid: %"PRId64"\n", s->czxid);   // PRId64 defined in inttypes.h
    fprintf(stderr,  "\t          mzxid: %"PRId64"\n", s->mzxid);
    fprintf(stderr,  "\t          ctime: %"PRId64"\n", s->ctime);
    fprintf(stderr,  "\t          mtime: %"PRId64"\n", s->mtime);
    fprintf(stderr,  "\t        version: %d\n",        s->version);
    fprintf(stderr,  "\t       cversion: %d\n",        s->cversion);
    fprintf(stderr,  "\t       aversion: %d\n",        s->aversion);
    fprintf(stderr,  "\t ephemeralOwner: %"PRId64"\n", s->ephemeralOwner);
    fprintf(stderr,  "\t     dataLength: %d\n",        s->dataLength);
    fprintf(stderr,  "\t    numChildren: %d\n",        s->numChildren);
    fprintf(stderr,  "\t          pzxid: %"PRId64"\n", s->pzxid);
    fprintf(stderr,  "}\n");
  } else {
    fprintf(stderr,  "stat { NULL }\n");
  }
}

zkrb_calling_context *zkrb_calling_context_alloc(int64_t req_id, zkrb_queue_t *queue) {
  zkrb_calling_context *ctx = zk_malloc(sizeof(zkrb_calling_context));
  if (!ctx) return NULL;

  ctx->req_id = req_id;
  ctx->queue  = queue;

  return ctx;
}

void zkrb_calling_context_free(zkrb_calling_context *ctx) {
  zk_free(ctx);
}

void zkrb_print_calling_context(zkrb_calling_context *ctx) {
  fprintf(stderr, "calling context (%p){\n", ctx);
  fprintf(stderr, "\treq_id = %"PRId64"\n", ctx->req_id);
  fprintf(stderr, "\tqueue  = %p\n", ctx->queue);
  fprintf(stderr, "}\n");
}

/*
  process completions that get queued to the watcher queue, translate events
  to completions that the ruby side dispatches via callbacks.

  The calling_ctx can be thought of as the outer shell that we discard in
  this macro after pulling out the gooey delicious center.
*/

#define ZKH_SETUP_EVENT(qptr, eptr) \
  zkrb_calling_context *ctx = (zkrb_calling_context *) calling_ctx; \
  zkrb_event_t *eptr = zkrb_event_alloc();                          \
  eptr->req_id = ctx->req_id;                                       \
  zkrb_queue_t *qptr = ctx->queue;                                  \
  if (eptr->req_id != ZKRB_GLOBAL_REQ) zk_free(ctx)

void zkrb_state_callback(
    zhandle_t *zh, int type, int state, const char *path, void *calling_ctx) {

  zkrb_debug("ZOOKEEPER_C_STATE WATCHER "
                    "type = %d, state = %d, path = %p, value = %s",
      type, state, (void *) path, path ? path : "NULL");

  /* save callback context */
  struct zkrb_watcher_completion *wc = zk_malloc(sizeof(struct zkrb_watcher_completion));
  wc->type  = type;
  wc->state = state;
  wc->path  = strdup(path);

  // This is unfortunate copy-pasta from ZKH_SETUP_EVENT with one change: we
  // check type instead of the req_id to see if we need to free the ctx.
  zkrb_calling_context *ctx = (zkrb_calling_context *) calling_ctx;
  zkrb_event_t *event = zkrb_event_alloc();
  event->req_id = ctx->req_id;
  zkrb_queue_t *queue = ctx->queue;
  if (type != ZOO_SESSION_EVENT) {
    zk_free(ctx);
    ctx = NULL;
  }

  event->type = ZKRB_WATCHER;
  event->completion.watcher_completion = wc;

  zkrb_enqueue(queue, event);
}

void zkrb_data_callback(
    int rc, const char *value, int value_len, const struct Stat *stat, const void *calling_ctx) {

  zkrb_debug("ZOOKEEPER_C_DATA WATCHER "
                "rc = %d (%s), value = %s, len = %d",
                rc, zerror(rc), value ? value : "NULL", value_len);

  /* copy data completion */
  struct zkrb_data_completion *dc = zk_malloc(sizeof(struct zkrb_data_completion));
  dc->data = NULL;
  dc->stat = NULL;
  dc->data_len = 0;

  if (value != NULL) {
    dc->data = zk_malloc(value_len);  // xmalloc may raise an exception, which means the above completion will leak
    dc->data_len = value_len;
    memcpy(dc->data, value, value_len);
  }

  if (stat != NULL) { dc->stat = zk_malloc(sizeof(struct Stat)); memcpy(dc->stat, stat, sizeof(struct Stat)); }

  ZKH_SETUP_EVENT(queue, event);
  event->rc = rc;
  event->type = ZKRB_DATA;
  event->completion.data_completion = dc;

  zkrb_enqueue(queue, event);
}

void zkrb_stat_callback(
    int rc, const struct Stat *stat, const void *calling_ctx) {
  zkrb_debug("ZOOKEEPER_C_STAT WATCHER "
                    "rc = %d (%s)", rc, zerror(rc));

  struct zkrb_stat_completion *sc = zk_malloc(sizeof(struct zkrb_stat_completion));
  sc->stat = NULL;
  if (stat != NULL) { sc->stat = zk_malloc(sizeof(struct Stat)); memcpy(sc->stat, stat, sizeof(struct Stat)); }

  ZKH_SETUP_EVENT(queue, event);
  event->rc = rc;
  event->type = ZKRB_STAT;
  event->completion.stat_completion = sc;

  zkrb_enqueue(queue, event);
}

void zkrb_string_callback(
    int rc, const char *string, const void *calling_ctx) {

  zkrb_debug("ZOOKEEPER_C_STRING WATCHER "
                    "rc = %d (%s)", rc, zerror(rc));

  struct zkrb_string_completion *sc = zk_malloc(sizeof(struct zkrb_string_completion));
  sc->value = NULL;
  if (string)
    sc->value = strdup(string);

  ZKH_SETUP_EVENT(queue, event);
  event->rc = rc;
  event->type = ZKRB_STRING;
  event->completion.string_completion = sc;

  zkrb_enqueue(queue, event);
}

void zkrb_strings_callback(
    int rc, const struct String_vector *strings, const void *calling_ctx) {
  zkrb_debug("ZOOKEEPER_C_STRINGS WATCHER "
                    "rc = %d (%s), calling_ctx = %p", rc, zerror(rc), calling_ctx);

  /* copy string vector */
  struct zkrb_strings_completion *sc = zk_malloc(sizeof(struct zkrb_strings_completion));
  sc->values = (strings != NULL) ? zkrb_clone_string_vector(strings) : NULL;

  ZKH_SETUP_EVENT(queue, event);
  event->rc = rc;
  event->type = ZKRB_STRINGS;
  event->completion.strings_completion = sc;

  zkrb_enqueue(queue, event);
}

void zkrb_strings_stat_callback(
    int rc, const struct String_vector *strings, const struct Stat *stat, const void *calling_ctx) {
  zkrb_debug("ZOOKEEPER_C_STRINGS_STAT WATCHER "
                    "rc = %d (%s), calling_ctx = %p", rc, zerror(rc), calling_ctx);

  struct zkrb_strings_stat_completion *sc = zk_malloc(sizeof(struct zkrb_strings_stat_completion));
  sc->stat = NULL;
  if (stat != NULL) { sc->stat = zk_malloc(sizeof(struct Stat)); memcpy(sc->stat, stat, sizeof(struct Stat)); }

  sc->values = (strings != NULL) ? zkrb_clone_string_vector(strings) : NULL;

  ZKH_SETUP_EVENT(queue, event);
  event->rc = rc;
  event->type = ZKRB_STRINGS_STAT;
  event->completion.strings_stat_completion = sc;

  zkrb_enqueue(queue, event);
}

void zkrb_void_callback(int rc, const void *calling_ctx) {
  zkrb_debug("ZOOKEEPER_C_VOID WATCHER "
                    "rc = %d (%s)", rc, zerror(rc));

  ZKH_SETUP_EVENT(queue, event);
  event->rc = rc;
  event->type = ZKRB_VOID;
  event->completion.void_completion = NULL;

  zkrb_enqueue(queue, event);
}

void zkrb_acl_callback(
    int rc, struct ACL_vector *acls, struct Stat *stat, const void *calling_ctx) {
  zkrb_debug("ZOOKEEPER_C_ACL WATCHER rc = %d (%s)", rc, zerror(rc));

  struct zkrb_acl_completion *ac = zk_malloc(sizeof(struct zkrb_acl_completion));
  ac->acl = NULL;
  ac->stat = NULL;
  if (acls != NULL) { ac->acl  = zkrb_clone_acl_vector(acls); }
  if (stat != NULL) { ac->stat = zk_malloc(sizeof(struct Stat)); memcpy(ac->stat, stat, sizeof(struct Stat)); }

  ZKH_SETUP_EVENT(queue, event);
  event->rc = rc;
  event->type = ZKRB_ACL;
  event->completion.acl_completion = ac;

  /* should be synchronized */
  zkrb_enqueue(queue, event);
}

VALUE zkrb_id_to_ruby(struct Id *id) {
  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, GET_SYM("scheme"), rb_str_new2(id->scheme));
  rb_hash_aset(hash, GET_SYM("id"), rb_str_new2(id->id));
  return hash;
}

VALUE zkrb_acl_to_ruby(struct ACL *acl) {
  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, GET_SYM("perms"), INT2NUM(acl->perms));
  rb_hash_aset(hash, GET_SYM("id"), zkrb_id_to_ruby(&(acl->id)));
  return hash;
}

// [wickman] TODO test zkrb_ruby_to_aclvector
// [slyphon] TODO size checking on acl_ary (cast to int)
struct ACL_vector * zkrb_ruby_to_aclvector(VALUE acl_ary) {
  Check_Type(acl_ary, T_ARRAY);

  struct ACL_vector *v = zk_malloc(sizeof(struct ACL_vector));
  allocate_ACL_vector(v, (int)RARRAY_LEN(acl_ary));

  int k;
  for (k = 0; k < v->count; ++k) {
    VALUE acl_val = rb_ary_entry(acl_ary, k);
    v->data[k] = zkrb_ruby_to_acl(acl_val);
  }

  return v;
}

// [wickman] TODO test zkrb_ruby_to_aclvector
struct ACL zkrb_ruby_to_acl(VALUE rubyacl) {
  struct ACL acl;

  VALUE perms  = rb_iv_get(rubyacl, "@perms");
  VALUE rubyid = rb_iv_get(rubyacl, "@id");
  acl.perms  = NUM2INT(perms);
  acl.id = zkrb_ruby_to_id(rubyid);

  return acl;
}

// [wickman] TODO zkrb_ruby_to_id error checking? test
struct Id zkrb_ruby_to_id(VALUE rubyid) {
  struct Id id;

  VALUE scheme = rb_iv_get(rubyid, "@scheme");
  VALUE ident  = rb_iv_get(rubyid, "@id");

  if (scheme != Qnil) {
    id.scheme = zk_malloc(RSTRING_LEN(scheme) + 1);
    strncpy(id.scheme, RSTRING_PTR(scheme), RSTRING_LEN(scheme));
    id.scheme[RSTRING_LEN(scheme)] = '\0';
  } else {
    id.scheme = NULL;
  }

  if (ident != Qnil) {
    id.id = zk_malloc(RSTRING_LEN(ident) + 1);
    strncpy(id.id, RSTRING_PTR(ident), RSTRING_LEN(ident));
    id.id[RSTRING_LEN(ident)] = '\0';
  } else {
    id.id = NULL;
  }

  return id;
}

VALUE zkrb_acl_vector_to_ruby(struct ACL_vector *acl_vector) {
  int i;
  VALUE ary = rb_ary_new2(acl_vector->count);
  for(i = 0; i < acl_vector->count; i++) {
    rb_ary_push(ary, zkrb_acl_to_ruby(acl_vector->data+i));
  }
  return ary;
}

VALUE zkrb_string_vector_to_ruby(struct String_vector *string_vector) {
  int i;
  VALUE ary = rb_ary_new2(string_vector->count);
  for(i = 0; i < string_vector->count; i++) {
    rb_ary_push(ary, rb_str_new2(string_vector->data[i]));
  }
  return ary;
}

VALUE zkrb_stat_to_rarray(const struct Stat* stat) {
  return rb_ary_new3(11,
             LL2NUM(stat->czxid),
             LL2NUM(stat->mzxid),
             LL2NUM(stat->ctime),
             LL2NUM(stat->mtime),
             INT2NUM(stat->version),
             INT2NUM(stat->cversion),
             INT2NUM(stat->aversion),
             LL2NUM(stat->ephemeralOwner),
             INT2NUM(stat->dataLength),
             INT2NUM(stat->numChildren),
             LL2NUM(stat->pzxid));
}

VALUE zkrb_stat_to_rhash(const struct Stat *stat) {
  VALUE ary = rb_hash_new();
  rb_hash_aset(ary, GET_SYM("czxid"),            LL2NUM(stat->czxid));
  rb_hash_aset(ary, GET_SYM("mzxid"),            LL2NUM(stat->mzxid));
  rb_hash_aset(ary, GET_SYM("ctime"),            LL2NUM(stat->ctime));
  rb_hash_aset(ary, GET_SYM("mtime"),            LL2NUM(stat->mtime));
  rb_hash_aset(ary, GET_SYM("version"),         INT2NUM(stat->version));
  rb_hash_aset(ary, GET_SYM("cversion"),        INT2NUM(stat->cversion));
  rb_hash_aset(ary, GET_SYM("aversion"),        INT2NUM(stat->aversion));
  rb_hash_aset(ary, GET_SYM("ephemeralOwner"),   LL2NUM(stat->ephemeralOwner));
  rb_hash_aset(ary, GET_SYM("dataLength"),      INT2NUM(stat->dataLength));
  rb_hash_aset(ary, GET_SYM("numChildren"),     INT2NUM(stat->numChildren));
  rb_hash_aset(ary, GET_SYM("pzxid"),            LL2NUM(stat->pzxid));
  return ary;
}

// [wickman] TODO test zkrb_clone_acl_vector
struct ACL_vector * zkrb_clone_acl_vector(struct ACL_vector * src) {
  struct ACL_vector * dst = zk_malloc(sizeof(struct ACL_vector));
  allocate_ACL_vector(dst, src->count);
  int k;
  for (k = 0; k < src->count; ++k) {
    struct ACL * elt = &src->data[k];
    dst->data[k].id.scheme = strdup(elt->id.scheme);
    dst->data[k].id.id     = strdup(elt->id.id);
    dst->data[k].perms = elt->perms;
  }
  return dst;
}

// [wickman] TODO test zkrb_clone_string_vector
struct String_vector * zkrb_clone_string_vector(const struct String_vector * src) {
  struct String_vector * dst = zk_malloc(sizeof(struct String_vector));
  allocate_String_vector(dst, src->count);
  int k;
  for (k = 0; k < src->count; ++k) {
    dst->data[k] = strdup(src->data[k]);
  }
  return dst;
}

// vim:sts=2:sw=2:et
