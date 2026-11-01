/*
 * Byte-array allocation without the zero fill: for a caller that writes every byte before the
 * array is read. A zero-length request is the empty array, as msBufferFrom returns; a length
 * outside 0 .. MS_LEN_MAX is the range error the zero-filling allocation raises.
 */

#ifndef MS_BYTES_ALLOC_H
#define MS_BYTES_ALLOC_H

#include "runtime/core/array.h"
#include <string.h>

static inline msUint8Array msBytesNewUninit(int64_t len) {
	if (len < 0 || len > MS_LEN_MAX) msRaiseRangeError(len, 0, MS_LEN_MAX);
	if (len == 0) return MS_EMPTY_UINT8_ARRAY;
	msUint8Payload* p = (msUint8Payload*)msMemAlloc(sizeof(msUint8Payload) + (size_t)len);
	p->cap = len;
	return (msUint8Array){len, p};
}

/* Bytes [lo, hi) of the source; the caller clamps to 0 <= lo <= hi <= srcLen. */
static inline msUint8Array msBytesSlice(const uint8_t* src, int64_t srcLen, int64_t lo, int64_t hi) {
	(void)srcLen;
	msUint8Array out = msBytesNewUninit(hi - lo);
	if (out.len > 0) memcpy(out.p->data, src + lo, (size_t)out.len);
	return out;
}

#endif
