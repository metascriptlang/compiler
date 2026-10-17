/* Stands in for musl's src/internal/libm.h: the helpers pow.c uses, with musl's definitions. */
#ifndef _LIBM_H
#define _LIBM_H
#include <stdint.h>
#include <math.h>
#include <features.h>

typedef double double_t;
#define WANT_ROUNDING 1
#define TOINT_INTRINSICS 0
#define issignaling_inline(x) 0
#define predict_true(x) __builtin_expect(!!(x), 1)
#define predict_false(x) __builtin_expect(x, 0)
#define asuint64(f) ((union{double _f; uint64_t _i;}){f})._i
#define asdouble(i) ((union{uint64_t _i; double _f;}){i})._f

static inline double eval_as_double(double x) { double y = x; return y; }
static inline double fp_barrier(double x) { volatile double y = x; return y; }
static inline void fp_force_eval(double x) { volatile double y; y = x; }
static inline double __math_xflow(uint32_t sign, double y) { return eval_as_double(fp_barrier(sign ? -y : y) * y); }
static inline double __math_oflow(uint32_t sign) { return __math_xflow(sign, 0x1p769); }
static inline double __math_uflow(uint32_t sign) { return __math_xflow(sign, 0x1p-767); }
static inline double __math_invalid(double x) { return (x - x) / (x - x); }
#endif
