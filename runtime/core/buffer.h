/*
 * MetaScript Buffer Runtime
 *
 * Buffer is uint8[] on every target; std/core/buffer holds its methods. This header only
 * gives them the payload's first byte, which is NULL for an array that never allocated.
 */

#ifndef MS_BUFFER_H
#define MS_BUFFER_H

#include "runtime/core/array.h"

static inline uint8_t* msBufferData(msUint8Array* buf) {
	return msArrDataOr0(buf->p);
}

#endif
