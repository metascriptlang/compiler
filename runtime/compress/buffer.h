#ifndef MS_COMPRESS_BUFFER_H
#define MS_COMPRESS_BUFFER_H

#include "runtime/core/array.h"
#include <string.h>

/* A fresh Buffer holding a copy of `len` bytes; the empty Buffer when len is 0. */
static inline msUint8Array msCompressBuffer(const uint8_t* data, int64_t len) {
    if (len <= 0) return MS_EMPTY_UINT8_ARRAY;
    msUint8Payload* p = (msUint8Payload*)msMemAlloc(sizeof(int64_t) + (size_t)len);
    p->cap = len;
    memcpy(p->data, data, (size_t)len);
    return (msUint8Array){len, p};
}

#endif
