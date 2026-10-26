/*
 * MetaScript Buffer Runtime
 * Binary data type — byte-oriented operations without UTF-8 interpretation.
 *
 * msBuffer = typedef msString (zero-cost, same 16-byte struct)
 * Redundant functions (get, length, slice, compare, equals, concat, copy)
 * are handled by msString* equivalents — only unique ops live here.
 */

#ifndef MS_BUFFER_H
#define MS_BUFFER_H

#include "runtime/core/string.h"

/* ===== Core Type ===== */

typedef msString msBuffer;
#define MS_EMPTY_BUFFER MS_EMPTY_STRING

/* ===== Allocation ===== */

msBuffer msBufferAlloc(int64_t size);
msBuffer msBufferAllocUnsafe(int64_t size);

#endif
