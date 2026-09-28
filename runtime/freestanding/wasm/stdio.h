#ifndef MS_FREESTANDING_STDIO_H
#define MS_FREESTANDING_STDIO_H
#include <stddef.h>
#include <stdarg.h>
typedef struct msFreestandingFile FILE;
#define EOF (-1)
#define stdin ((FILE*)0)
#define stdout ((FILE*)1)
#define stderr ((FILE*)2)
int printf(const char* restrict format, ...);
int fprintf(FILE* restrict file, const char* restrict format, ...);
int puts(const char* s);
int fputs(const char* restrict s, FILE* restrict file);
int fputc(int c, FILE* file);
size_t fwrite(const void* restrict ptr, size_t size, size_t count, FILE* restrict file);
size_t fread(void* restrict ptr, size_t size, size_t count, FILE* restrict file);
int fflush(FILE* file);
int snprintf(char* restrict dst, size_t size, const char* restrict format, ...);
int vsnprintf(char* restrict dst, size_t size, const char* restrict format, va_list args);
#endif
