#ifndef ZKRB_COMMON_H
#define ZKRB_COMMON_H

#include "ruby.h"

//#define THREADED
#undef THREADED    // we are linking against the zookeeper_st lib, this is crucial

#ifndef RB_GC_GUARD_PTR
#define RB_GC_GUARD_PTR(V) (V);
#endif
#ifndef RB_GC_GUARD
#define RB_GC_GUARD(V) (V);
#endif


#endif /* ZKRB_COMMON_H */
