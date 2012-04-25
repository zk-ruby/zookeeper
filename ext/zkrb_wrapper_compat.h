#ifndef ZKRB_WRAPPER_COMPAT_H
#define ZKRB_WRAPPER_COMPAT_H

typedef VALUE zkrb_blocking_function_t(void *);
typedef void zkrb_unblock_function_t(void *);

VALUE zkrb_thread_blocking_region(zkrb_blocking_function_t *func, void *data1, 
																		zkrb_unblock_function_t *ubf, void *data2);


#endif /* ZKRB_WRAPPER_COMPAT_H */
