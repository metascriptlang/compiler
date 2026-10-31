#ifndef MS_CHECKS_H
#define MS_CHECKS_H

static inline int64_t msSliceLen(int64_t start, int64_t end, int64_t len) {
	if (end != start && (start < 0 || end < start || end > len)) msRaiseSliceError(start, end, len);
	return end - start;
}
#define msSliceLenUnchecked(start, end, len) ((int64_t)(end) - (int64_t)(start))

/* Converting a double outside the destination's range, NaN included, is
   undefined in C (C11 6.3.1.4): the bounds are tested on the double first. */
static inline double msCheckRangeF(double v, int64_t lo, int64_t hi) {
	if (!(v > (double)lo - 1.0 && v < (double)hi + 1.0)) msRaiseRangeErrorF(v, lo, hi);
	return v;
}

static inline int64_t msCheckRangeS(int64_t v, int64_t lo, int64_t hi) {
	if (v < lo || v > hi) msRaiseRangeError(v, lo, hi);
	return v;
}

static inline uint64_t msCheckRangeU(uint64_t v, int64_t lo, int64_t hi) {
	if (hi < 0 || v > (uint64_t)hi || (lo > 0 && v < (uint64_t)lo)) msRaiseRangeErrorU64(v, lo, hi);
	return v;
}

#define msCheckRangeOf(v, lo, hi) _Generic((v), \
	double: msCheckRangeF, float: msCheckRangeF, \
	unsigned long: msCheckRangeU, unsigned long long: msCheckRangeU, \
	default: msCheckRangeS)((v), (lo), (hi))

#define msCheckRangeI8(v, lo, hi) ((int8_t)msCheckRangeOf((v), (lo), (hi)))
#define msCheckRangeU8(v, lo, hi) ((uint8_t)msCheckRangeOf((v), (lo), (hi)))
#define msCheckRangeI16(v, lo, hi) ((int16_t)msCheckRangeOf((v), (lo), (hi)))
#define msCheckRangeU16(v, lo, hi) ((uint16_t)msCheckRangeOf((v), (lo), (hi)))
#define msCheckRangeI32(v, lo, hi) ((int32_t)msCheckRangeOf((v), (lo), (hi)))
#define msCheckRangeU32(v, lo, hi) ((uint32_t)msCheckRangeOf((v), (lo), (hi)))

static inline int64_t msCheckRangeI64(double v) {
	if (!(v >= -9223372036854775808.0 && v < 9223372036854775808.0)) msRaiseRangeErrorF(v, INT64_MIN, INT64_MAX);
	return (int64_t)v;
}

static inline uint64_t msCheckRangeU64(double v) {
	if (!(v > -1.0 && v < 18446744073709551616.0)) msRaiseRangeErrorFToU64(v);
	return (uint64_t)v;
}

static inline int64_t msCheckRangeI64FromU64(uint64_t v) {
	if (v > (uint64_t)INT64_MAX) msRaiseRangeErrorU64(v, INT64_MIN, INT64_MAX);
	return (int64_t)v;
}


#endif
