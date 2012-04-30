#ifndef ZKRB_WRAPPER_COMPAT_H
#define ZKRB_WRAPPER_COMPAT_H

typedef VALUE zkrb_blocking_function_t(void *);
typedef void zkrb_unblock_function_t(void *);

// delegates to rb_thread_blocking_region on 1.9.x, always uses UBF_IO
VALUE zkrb_thread_blocking_region(zkrb_blocking_function_t *func, void *data1);


#endif /* ZKRB_WRAPPER_COMPAT_H */
