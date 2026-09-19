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
double trunc(double x);
double sqrt(double x);
double cbrt(double x);
double exp(double x);
double expm1(double x);
double log(double x);
double log1p(double x);
double log2(double x);
double log10(double x);
double hypot(double x, double y);
double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);
double atan2(double y, double x);
double sinh(double x);
double cosh(double x);
double tanh(double x);
double asinh(double x);
double acosh(double x);
double atanh(double x);
int isinf(double x);
int isnan(double x);
int isfinite(double x);
#endif
