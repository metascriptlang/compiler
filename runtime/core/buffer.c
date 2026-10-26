/*
 * MetaScript Buffer Runtime — C Implementation
 *
 * Binary data operations: alloc, create, convert, byte access,
 * slice/copy/fill, compare, read/write integers (LE/BE).
 *
 * msBuffer is typedef msString — same struct, different semantics.
 * Key: msBufferLength returns buf.len (true byte count).
 */

#include "runtime/core/system.h"
#include <stdlib.h>
#include <string.h>

/* ===== Allocation ===== */

msBuffer msBufferAlloc(int64_t size) {
	if (size <= 0) return MS_EMPTY_BUFFER;
	if (size > MS_LEN_MAX) msRaiseRangeError(size, 0, MS_LEN_MAX);

	msStrPayload* p = (msStrPayload*)msMemAlloc0(sizeof(msStrPayload) + size + 1);

	p->cap = size;
	/* calloc zero-fills data; null-terminate for safety */
	p->data[size] = '\0';

	msBuffer buf;
	buf.len = size;
	buf.p = p;
	return buf;
}

msBuffer msBufferAllocUnsafe(int64_t size) {
	if (size <= 0) return MS_EMPTY_BUFFER;
	if (size > MS_LEN_MAX) msRaiseRangeError(size, 0, MS_LEN_MAX);

	msStrPayload* p = (msStrPayload*)msMemAlloc(sizeof(msStrPayload) + size + 1);

	p->cap = size;
	p->data[size] = '\0';  /* null-terminate only */

	msBuffer buf;
	buf.len = size;
	buf.p = p;
	return buf;
}
