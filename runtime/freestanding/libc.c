#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "runtime/allocator.h"

#if MS_HEAP_USE_MALLOC
#error "freestanding libc requires the custom heap backend"
#endif

void* memcpy(void* restrict dst, const void* restrict src, size_t n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void* memmove(void* dst, const void* src, size_t n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    if ((uintptr_t)d <= (uintptr_t)s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (size_t i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

void* memset(void* dst, int c, size_t n) {
    unsigned char* d = dst;
    for (size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

void* memchr(const void* src, int c, size_t n) {
    const unsigned char* s = src;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == (unsigned char)c) return (void*)(s + i);
    }
    return NULL;
}

int memcmp(const void* a, const void* b, size_t n) {
    const unsigned char* x = a;
    const unsigned char* y = b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) return (int)x[i] - (int)y[i];
    }
    return 0;
}

size_t strlen(const char* s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

int strcmp(const char* a, const char* b) {
    while (*a && *a == *b) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char* a, const char* b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i] || !a[i]) {
            return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
        }
    }
    return 0;
}

char* strchr(const char* s, int c) {
    for (;;) {
        if (*s == (char)c) return (char*)s;
        if (!*s) return NULL;
        s++;
    }
}

char* strrchr(const char* s, int c) {
    const char* found = NULL;
    do {
        if (*s == (char)c) found = s;
    } while (*s++);
    return (char*)found;
}

char* strstr(const char* haystack, const char* needle) {
    if (!*needle) return (char*)haystack;
    const size_t n = strlen(needle);
    for (; *haystack; haystack++) {
        if (*haystack == *needle && strncmp(haystack, needle, n) == 0) return (char*)haystack;
    }
    return NULL;
}

char* strcpy(char* restrict dst, const char* restrict src) {
    size_t i = 0;
    do { dst[i] = src[i]; } while (src[i++]);
    return dst;
}

char* strncpy(char* restrict dst, const char* restrict src, size_t n) {
    size_t i = 0;
    for (; i < n && src[i]; i++) dst[i] = src[i];
    for (; i < n; i++) dst[i] = 0;
    return dst;
}

static void msFreestandingSwap(unsigned char* a, unsigned char* b, size_t size) {
    while (size--) {
        unsigned char value = *a;
        *a++ = *b;
        *b++ = value;
    }
}

static void msFreestandingSiftDown(unsigned char* base, size_t root, size_t end, size_t size,
                                   int (*cmp)(const void*, const void*)) {
    while (root < end / 2) {
        size_t child = 2 * root + 1;
        if (child + 1 < end && cmp(base + child * size, base + (child + 1) * size) < 0) child++;
        if (cmp(base + root * size, base + child * size) >= 0) return;
        msFreestandingSwap(base + root * size, base + child * size, size);
        root = child;
    }
}

void qsort(void* base, size_t count, size_t size, int (*cmp)(const void*, const void*)) {
    unsigned char* bytes = base;
    if (count < 2 || size == 0) return;
    if (count > SIZE_MAX / size) abort();
    for (size_t i = count / 2; i-- > 0;) msFreestandingSiftDown(bytes, i, count, size, cmp);
    for (size_t end = count - 1; end > 0; end--) {
        msFreestandingSwap(bytes, bytes + end * size, size);
        msFreestandingSiftDown(bytes, 0, end, size, cmp);
    }
}

typedef union {
    size_t size;
    max_align_t alignment;
} msAllocationHeader;

void msArenaReset(void) {
    msHeapReset();
}

void* msArenaAlloc(size_t size) {
    return calloc(1, size);
}

void* malloc(size_t size) {
    if (size > SIZE_MAX - sizeof(msAllocationHeader)) return NULL;
    msAllocationHeader* header = msHeapAlloc(sizeof(msAllocationHeader) + size);
    header->size = size;
    return header + 1;
}

void* calloc(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) return NULL;
    size_t bytes = count * size;
    void* ptr = malloc(bytes);
    if (ptr) memset(ptr, 0, bytes);
    return ptr;
}

void free(void* ptr) {
    if (ptr) msHeapFree((msAllocationHeader*)ptr - 1);
}

void* msRealloc(void* old, size_t oldSize, size_t newSize) {
    if (!newSize) {
        free(old);
        return NULL;
    }
    if (!old) return malloc(newSize);
    if (newSize > SIZE_MAX - sizeof(msAllocationHeader)) return NULL;
    size_t copied = oldSize < newSize ? oldSize : newSize;
    msAllocationHeader* header = (msAllocationHeader*)old - 1;
    header = msHeapRealloc(header, sizeof(*header) + copied,
                          sizeof(*header) + newSize);
    header->size = newSize;
    return header + 1;
}

void* realloc(void* old, size_t size) {
    if (!old) return malloc(size);
    const msAllocationHeader* header = (const msAllocationHeader*)old - 1;
    return msRealloc(old, header->size, size);
}

_Noreturn void abort(void) { __builtin_trap(); }
_Noreturn void exit(int status) { (void)status; __builtin_trap(); }
int printf(const char* restrict format, ...) { (void)format; __builtin_trap(); }
int fprintf(FILE* restrict file, const char* restrict format, ...) {
    (void)file; (void)format; __builtin_trap();
}
int puts(const char* s) { (void)s; __builtin_trap(); }
int fputs(const char* restrict s, FILE* restrict file) {
    (void)s; (void)file; __builtin_trap();
}
int fputc(int c, FILE* file) { (void)c; (void)file; __builtin_trap(); }
size_t fwrite(const void* restrict ptr, size_t size, size_t count, FILE* restrict file) {
    (void)ptr; (void)size; (void)count; (void)file; __builtin_trap();
}
size_t fread(void* restrict ptr, size_t size, size_t count, FILE* restrict file) {
    (void)ptr; (void)size; (void)count; (void)file; __builtin_trap();
}
int fflush(FILE* file) { (void)file; __builtin_trap(); }
