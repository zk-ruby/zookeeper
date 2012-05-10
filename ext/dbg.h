#ifndef __dbg_h__
#define __dbg_h__

// ALL GLORY TO THE Zed A. Shaw
// http://c.learncodethehardway.org/book/learn-c-the-hard-waych21.html#x26-10500021

#include <stdio.h>
#include <errno.h>
#include <string.h>

#ifdef NDEBUG
#define debug(M, ...)
#else
#define debug(M, ...) fprintf(stderr, "DEBUG %s:%d: " M "\n", __FILE__, __LINE__, ##__VA_ARGS__)
#endif

#define clean_errno() (errno == 0 ? "None" : strerror(errno))

#define log_err(M, ...) fprintf(stderr, "[ERROR] (%s:%d: errno: %s) " M "\n", __FILE__, __LINE__, clean_errno(), ##__VA_ARGS__) 

#define log_warn(M, ...) fprintf(stderr, "[WARN] (%s:%d: errno: %s) " M "\n", __FILE__, __LINE__, clean_errno(), ##__VA_ARGS__) 

#define log_info(M, ...) fprintf(stderr, "[INFO] (%s:%d) " M "\n", __FILE__, __LINE__, ##__VA_ARGS__) 

// acts to assert that A is true
#define check(A, M, ...) if(!(A)) { log_err(M, ##__VA_ARGS__); errno=0; goto error; } 

// like check, but provide an explicit goto label name
#define check_goto(A, L, M, ...) if(!(A)) { log_err(M, ##__VA_ARGS__); errno=0; goto L; } 

// like check, but implicit jump to 'unlock' label
#define check_unlock(A, M, ...) check_goto(A, unlock, M, ##__VA_ARGS__)

#define sentinel(M, ...)  { log_err(M, ##__VA_ARGS__); errno=0; goto error; } 

#define check_mem(A) check((A), "Out of memory.")

// checks the condition A, if not true, logs the message M given using zkrb_debug
// then does a goto to the label L 
#define check_debug_goto(A, L, M, ...) if(!(A)) { zkrb_debug(M, ##__VA_ARGS__); errno=0; goto L; } 

// check_debug_goto with implicit 'unlock' label
#define check_debug_unlock(A, M, ...) check_debug_goto(A, unlock, M, ##__VA_ARGS__) 

// like check_debug_goto, but the label is implicitly 'error'
#define check_debug(A, M, ...) check_debug_goto(A, error, M, ##__VA_ARGS__) 

#define zkrb_debug(M, ...) if (ZKRBDebugging) fprintf(stderr, "DEBUG %p:%s:%d: " M "\n", (void *)pthread_self(), __FILE__, __LINE__, ##__VA_ARGS__)
#define zkrb_debug_inst(O, M, ...) zkrb_debug("obj_id: %lx, " M, FIX2LONG(rb_obj_id(O)), ##__VA_ARGS__)

// __dbg_h__
#endif

