#include "ruby.h"
#include "zkrb_wrapper_compat.h"


VALUE zkrb_thread_blocking_region(zkrb_blocking_function_t *func, void *data1) {

#ifdef HAVE_RB_THREAD_BLOCKING_REGION
  return rb_thread_blocking_region((rb_blocking_function_t *)func, data1, RUBY_UBF_IO, 0);
#else
  return func(data1);
#endif

}

// vim:sts=2:sw=2:et
