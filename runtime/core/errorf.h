#ifndef MS_ERRORF_H
#define MS_ERRORF_H

#include <stdio.h>

#if !defined(MSOS_BARE) && !defined(MSOS_SOLANA) && (defined(__wasi__) || (defined(__linux__) && !defined(__GLIBC__) && !defined(__ANDROID__)))
#define MS_ERRORF_OWN_FORMATTER 1
void msErrorf(const char* format, ...) __attribute__((format(printf, 1, 2), cold));
#else
#define msErrorf(...) fprintf(stderr, __VA_ARGS__)
#endif

#endif /* MS_ERRORF_H */
