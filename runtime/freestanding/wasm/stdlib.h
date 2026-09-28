#ifndef MS_FREESTANDING_STDLIB_H
#define MS_FREESTANDING_STDLIB_H
#include <stddef.h>
void* malloc(size_t size);
void* calloc(size_t count, size_t size);
void* realloc(void* old, size_t size);
void free(void* ptr);
void qsort(void* base, size_t count, size_t size, int (*cmp)(const void*, const void*));
_Noreturn void abort(void);
_Noreturn void exit(int status);
double strtod(const char* restrict s, char** restrict end);
long strtol(const char* restrict s, char** restrict end, int base);
long long strtoll(const char* restrict s, char** restrict end, int base);
unsigned long strtoul(const char* restrict s, char** restrict end, int base);
unsigned long long strtoull(const char* restrict s, char** restrict end, int base);
#endif
