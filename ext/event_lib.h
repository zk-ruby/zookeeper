#ifndef ZKRB_EVENT_LIB_H
#define ZKRB_EVENT_LIB_H

#include "ruby.h"
#include "zookeeper/zookeeper.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define ZK_TRUE 1
#define ZK_FALSE 0
#define ZKRB_GLOBAL_REQ -1

// (slyphon): this RC value does not conflict with any of the ZOO_ERRORS
// but need to find a better way of formalizing and defining this stuff
#define ZKRB_ERR_REQ -2
#define ZKRB_ERR_RC -15

#ifndef RSTRING_LEN
# define RSTRING_LEN(x) RSTRING(x)->len
#endif
#ifndef RSTRING_PTR
# define RSTRING_PTR(x) RSTRING(x)->ptr
#endif
#ifndef RARRAY_LEN
# define RARRAY_LEN(x) RARRAY(x)->len
#endif

extern int ZKRBDebugging;
extern pthread_mutex_t zkrb_q_mutex;

struct zkrb_data_completion {
  char *data;
  int data_len;
  struct Stat *stat;
};

struct zkrb_stat_completion {
  struct Stat *stat;
};

struct zkrb_void_completion {
};

struct zkrb_string_completion {
  char *value;  
};

struct zkrb_strings_completion {
  struct String_vector *values;
};

struct zkrb_strings_stat_completion {
  struct String_vector *values;
  struct Stat *stat;
};

struct zkrb_acl_completion {
  struct ACL_vector *acl;
  struct Stat *stat;
};

struct zkrb_watcher_completion {
  int type;
  int state;
  char *path;
};

typedef struct {
  int64_t req_id;
  int rc;

  enum {
    ZKRB_DATA         = 0,
    ZKRB_STAT         = 1,
    ZKRB_VOID         = 2,
    ZKRB_STRING       = 3,
    ZKRB_STRINGS      = 4,
    ZKRB_STRINGS_STAT = 5,
    ZKRB_ACL          = 6,
    ZKRB_WATCHER      = 7
  } type;
  
  union {
    struct zkrb_data_completion         *data_completion;
    struct zkrb_stat_completion         *stat_completion;
    struct zkrb_void_completion         *void_completion;
    struct zkrb_string_completion       *string_completion;
    struct zkrb_strings_completion      *strings_completion;
    struct zkrb_strings_stat_completion *strings_stat_completion;
    struct zkrb_acl_completion          *acl_completion;
    struct zkrb_watcher_completion      *watcher_completion;
  } completion;
} zkrb_event_t;

struct zkrb_event_ll {
  zkrb_event_t         *event;
  struct zkrb_event_ll *next;
};

typedef struct zkrb_event_ll zkrb_event_ll_t;

typedef struct {
  zkrb_event_ll_t *head;
  zkrb_event_ll_t *tail;
  int             pipe_read;
  int             pipe_write;
  pid_t           orig_pid;
} zkrb_queue_t;

zkrb_queue_t * zkrb_queue_alloc(void);
void           zkrb_queue_free(zkrb_queue_t *queue);
zkrb_event_t * zkrb_event_alloc(void);
void           zkrb_event_free(zkrb_event_t *ptr);

void                 zkrb_enqueue(zkrb_queue_t *queue, zkrb_event_t *elt);
zkrb_event_t *       zkrb_peek(zkrb_queue_t *queue);
zkrb_event_t *       zkrb_dequeue(zkrb_queue_t *queue, int need_lock);
void                 zkrb_signal(zkrb_queue_t *queue);

void zkrb_print_stat(const struct Stat *s);

typedef struct {
  int64_t        req_id;
  zkrb_queue_t   *queue;
} zkrb_calling_context;

void zkrb_print_calling_context(zkrb_calling_context *ctx);
zkrb_calling_context *zkrb_calling_context_alloc(int64_t req_id, zkrb_queue_t *queue);
void zkrb_calling_context_free(zkrb_calling_context *ctx);

/*
  default process completions that get queued into the ruby client event queue
*/

void zkrb_state_callback(
    zhandle_t *zh, int type, int state, const char *path, void *calling_ctx);

void zkrb_data_callback(
    int rc, const char *value, int value_len, const struct Stat *stat, const void *calling_ctx);

void zkrb_stat_callback(
    int rc, const struct Stat *stat, const void *calling_ctx);

void zkrb_string_callback(
    int rc, const char *string, const void *calling_ctx);

void zkrb_strings_callback(
    int rc, const struct String_vector *strings, const void *calling_ctx);

void zkrb_strings_stat_callback(
    int rc, const struct String_vector *strings, const struct Stat* stat, const void *calling_ctx);

void zkrb_void_callback(
    int rc, const void *calling_ctx);

void zkrb_acl_callback(
    int rc, struct ACL_vector *acls, struct Stat *stat, const void *calling_ctx);

VALUE zkrb_event_to_ruby(zkrb_event_t *event);
VALUE zkrb_acl_to_ruby(struct ACL *acl);
VALUE zkrb_acl_vector_to_ruby(struct ACL_vector *acl_vector);
VALUE zkrb_id_to_ruby(struct Id *id);
VALUE zkrb_string_vector_to_ruby(struct String_vector *string_vector);
VALUE zkrb_stat_to_rarray(const struct Stat *stat);
VALUE zkrb_stat_to_rhash(const struct Stat* stat);

struct ACL_vector *    zkrb_ruby_to_aclvector(VALUE acl_ary);
struct ACL_vector *    zkrb_clone_acl_vector(struct ACL_vector * src);
struct String_vector * zkrb_clone_string_vector(const struct String_vector * src);
struct ACL             zkrb_ruby_to_acl(VALUE rubyacl);
struct Id              zkrb_ruby_to_id(VALUE rubyid);

#endif  /* ZKRB_EVENT_LIB_H */
