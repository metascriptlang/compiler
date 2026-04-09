/* Freestanding stub — minimal math for BPF */
#ifndef _MATH_H
#define _MATH_H
#include <stdint.h>
#define NAN       __builtin_nan("")
#define INFINITY  __builtin_inf()
static inline double fabs(double x) { return x < 0 ? -x : x; }
static inline double floor(double x) { return (double)(int64_t)x - (x < (double)(int64_t)x ? 1.0 : 0.0); }
static inline double ceil(double x)  { return (double)(int64_t)x + (x > (double)(int64_t)x ? 1.0 : 0.0); }
static inline double fmod(double a, double b) { return a - (double)(int64_t)(a / b) * b; }
static inline double pow(double base, double exp) {
    if (exp == 0.0) return 1.0;
    double result = 1.0;
    int64_t n = (int64_t)exp;
    for (int64_t i = 0; i < (n < 0 ? -n : n); i++) result *= base;
    return n < 0 ? 1.0 / result : result;
}
#endif
