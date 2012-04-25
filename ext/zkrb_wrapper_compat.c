#include "ruby.h"
#include "zkrb_wrapper_compat.h"


VALUE zkrb_thread_blocking_region(zkrb_blocking_function_t *func, void *data1, 
																		zkrb_unblock_function_t *ubf, void *data2) {

#if (RUBY_VERSION_MAJOR == 1 && RUBY_VERSION_MINOR == 8)
	return func(data1);
#else
	return rb_thread_blocking_region((rb_blocking_function_t *)func, data1, (rb_unblock_function_t *)ubf, data2);
#endif

}


