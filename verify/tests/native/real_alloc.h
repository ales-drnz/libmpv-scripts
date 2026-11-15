// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The allocator under a test that replaces malloc(), calloc(), realloc() or
// posix_memalign() for its process: AddressSanitizer's when the test is
// built with it, else the next one in the lookup order (the C library's,
// which valgrind tracks in the MEMCHECK=1 run). Include it first: it needs
// _GNU_SOURCE for RTLD_NEXT.
#ifndef REAL_ALLOC_H
#define REAL_ALLOC_H

#ifdef __SANITIZE_ADDRESS__
#include <stddef.h>
extern void *__interceptor_malloc(size_t n);
extern void *__interceptor_calloc(size_t nmemb, size_t n);
extern void *__interceptor_realloc(void *p, size_t n);
extern int __interceptor_posix_memalign(void **p, size_t align, size_t size);
#define real_malloc __interceptor_malloc
#define real_calloc __interceptor_calloc
#define real_realloc __interceptor_realloc
#define real_posix_memalign __interceptor_posix_memalign
#else
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <stddef.h>
// dlsym() does not allocate when it finds the symbol, so the first call of
// a replaced function does not come back here.
static inline void *real_malloc(size_t n)
{
    static void *(*f)(size_t);
    if (!f)
        f = (void *(*)(size_t))dlsym(RTLD_NEXT, "malloc");
    return f(n);
}
static inline void *real_calloc(size_t nmemb, size_t n)
{
    static void *(*f)(size_t, size_t);
    if (!f)
        f = (void *(*)(size_t, size_t))dlsym(RTLD_NEXT, "calloc");
    return f(nmemb, n);
}
static inline void *real_realloc(void *p, size_t n)
{
    static void *(*f)(void *, size_t);
    if (!f)
        f = (void *(*)(void *, size_t))dlsym(RTLD_NEXT, "realloc");
    return f(p, n);
}
static inline int real_posix_memalign(void **p, size_t align, size_t size)
{
    static int (*f)(void **, size_t, size_t);
    if (!f)
        f = (int (*)(void **, size_t, size_t))dlsym(RTLD_NEXT, "posix_memalign");
    return f(p, align, size);
}
#endif

#endif
