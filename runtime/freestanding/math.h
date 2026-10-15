/* Freestanding stub — minimal math for BPF */
#ifndef _MATH_H
#define _MATH_H
#include <stdint.h>
#define NAN       __builtin_nan("")
#define INFINITY  __builtin_inf()
static inline double fabs(double x) { return x < 0 ? -x : x; }
#define MS_DOUBLES_ARE_INTEGERS_FROM 4503599627370496.0
static inline double trunc(double x) {
    if (!(fabs(x) < MS_DOUBLES_ARE_INTEGERS_FROM)) return x;
    double whole = (double)(int64_t)x;
    return whole == 0.0 ? x * 0.0 : whole;
}
static inline double floor(double x) { double t = trunc(x); return t > x ? t - 1.0 : t; }
static inline double ceil(double x)  { double t = trunc(x); return t < x ? t + 1.0 : t; }
static inline double fmod(double x, double y) {
    union { double f; uint64_t i; } ux = { x }, uy = { y };
    int ex = (int)(ux.i >> 52 & 0x7ff), ey = (int)(uy.i >> 52 & 0x7ff);
    uint64_t sign = ux.i >> 63, xi = ux.i, yi = uy.i, i;
    if (yi << 1 == 0 || y != y || ex == 0x7ff) return (x * y) / (x * y);
    if (xi << 1 <= yi << 1) return xi << 1 == yi << 1 ? 0 * x : x;
    if (ex == 0) {
        for (i = xi << 12; i >> 63 == 0; ex--, i <<= 1) {}
        xi <<= -ex + 1;
    } else {
        xi = (xi & (UINT64_MAX >> 12)) | (1ULL << 52);
    }
    if (ey == 0) {
        for (i = yi << 12; i >> 63 == 0; ey--, i <<= 1) {}
        yi <<= -ey + 1;
    } else {
        yi = (yi & (UINT64_MAX >> 12)) | (1ULL << 52);
    }
    for (; ex > ey; ex--) {
        i = xi - yi;
        if (i >> 63 == 0) {
            if (i == 0) return 0 * x;
            xi = i;
        }
        xi <<= 1;
    }
    i = xi - yi;
    if (i >> 63 == 0) {
        if (i == 0) return 0 * x;
        xi = i;
    }
    for (; xi >> 52 == 0; xi <<= 1, ex--) {}
    if (ex > 0) xi = (xi - (1ULL << 52)) | ((uint64_t)ex << 52);
    else xi >>= -ex + 1;
    ux.i = xi | sign << 63;
    return ux.f;
}
#define MS_POW_SATURATES_FROM 9223372036854775808.0
static inline double ms_pow_by_squaring(double x, int64_t n) {
    double r = 1.0;
    for (;;) {
        if (n & 1) r *= x;
        n >>= 1;
        if (n == 0) return r;
        x *= x;
    }
}
static inline double pow(double x, double y) {
    if (y == 0.0 || x == 1.0) return 1.0;
    if (x != x || y != y) return x + y;
    double ax = fabs(x);
    if (!(fabs(y) < MS_POW_SATURATES_FROM)) {
        if (ax == 1.0) return 1.0;
        return (ax > 1.0) == (y > 0.0) ? INFINITY : 0.0;
    }
    if (trunc(y) != y) {
        if (ax == 0.0 || ax == INFINITY) return (ax == 0.0) == (y > 0.0) ? 0.0 : INFINITY;
        if (x < 0.0) return NAN;
        __builtin_trap();
    }
    int64_t n = (int64_t)fabs(y);
    double r = ms_pow_by_squaring(x, n);
    if (y > 0.0) return r;
    if (fabs(r) == INFINITY) return ms_pow_by_squaring(1.0 / x, n);
    return 1.0 / r;
}
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
#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#endif
