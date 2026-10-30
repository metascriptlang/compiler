/*
 * MetaScript Buffer Runtime
 *
 * Buffer is uint8[] on every target; std/core/buffer holds its methods. This header only
 * gives them the payload's first byte, which is NULL for an array that never allocated.
 */

#ifndef MS_BUFFER_H
#define MS_BUFFER_H

#include "runtime/core/array.h"
#include <string.h>

static inline uint8_t* msBufferData(msUint8Array* buf) {
	return msArrDataOr0(buf->p);
}

static inline msUint8Array msBufferFrom(const uint8_t* data, int64_t len) {
	if (len <= 0) return MS_EMPTY_UINT8_ARRAY;
	msUint8Payload* p = (msUint8Payload*)msMemAlloc(sizeof(msUint8Payload) + (size_t)len);
	p->cap = len;
	memcpy(p->data, data, (size_t)len);
	return (msUint8Array){len, p};
}

#endif
