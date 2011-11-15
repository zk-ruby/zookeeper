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

#define check(A, M, ...) if(!(A)) { log_err(M, ##__VA_ARGS__); errno=0; goto error; } 

#define sentinel(M, ...)  { log_err(M, ##__VA_ARGS__); errno=0; goto error; } 

#define check_mem(A) check((A), "Out of memory.")

#define check_debug(A, M, ...) if(!(A)) { debug(M, ##__VA_ARGS__); errno=0; goto error; } 

#define zkrb_debug(M, ...) if (ZKRBDebugging) fprintf(stderr, "DEBUG %s:%d: " M "\n", __FILE__, __LINE__, ##__VA_ARGS__)
#define zkrb_debug_inst(O, M, ...) zkrb_debug("obj_id: %lx, " M, FIX2LONG(rb_obj_id(O)), ##__VA_ARGS__)

#endif

