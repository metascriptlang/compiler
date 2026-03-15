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

#include "std/core/string/native.h"

/* ===== Core Type ===== */

typedef msString msBuffer;
#define MS_EMPTY_BUFFER MS_EMPTY_STRING

/* ===== Allocation ===== */

msBuffer msBufferAlloc(int64_t size);
msBuffer msBufferAllocUnsafe(int64_t size);

/* ===== Creation ===== */

msBuffer msBufferFromString(msString str);

/* ===== Encoding ===== */

msBuffer msBufferFromHex(msString hex);
msBuffer msBufferFromBase64(msString b64);
msString msBufferToHex(msBuffer buf);
msString msBufferToBase64(msBuffer buf);

/* ===== Byte Write (string has no byte-level write) ===== */

void msBufferSet(msBuffer buf, int64_t index, int64_t value);

/* ===== Cross-Buffer Copy ===== */

int64_t msBufferCopy(msBuffer src, msBuffer dst, int64_t dstStart, int64_t srcStart, int64_t srcEnd);

/* ===== Fill ===== */

msBuffer msBufferFill(msBuffer buf, int64_t value, int64_t start, int64_t end);

/* ===== Read Integers ===== */

int64_t msBufferReadUint8(msBuffer buf, int64_t offset);
int64_t msBufferReadUint16LE(msBuffer buf, int64_t offset);
int64_t msBufferReadUint16BE(msBuffer buf, int64_t offset);
int64_t msBufferReadUint32LE(msBuffer buf, int64_t offset);
int64_t msBufferReadUint32BE(msBuffer buf, int64_t offset);
int64_t msBufferReadInt32LE(msBuffer buf, int64_t offset);
int64_t msBufferReadInt32BE(msBuffer buf, int64_t offset);

/* ===== Write Integers (return next offset) ===== */

int64_t msBufferWriteUint8(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteUint16LE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteUint16BE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteUint32LE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteUint32BE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteInt32LE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteInt32BE(msBuffer buf, int64_t value, int64_t offset);

/* ===== Signed 8/16-bit ===== */

int64_t msBufferReadInt8(msBuffer buf, int64_t offset);
int64_t msBufferReadInt16LE(msBuffer buf, int64_t offset);
int64_t msBufferReadInt16BE(msBuffer buf, int64_t offset);
int64_t msBufferWriteInt8(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteInt16LE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteInt16BE(msBuffer buf, int64_t value, int64_t offset);

/* ===== Float/Double ===== */

double msBufferReadFloatLE(msBuffer buf, int64_t offset);
double msBufferReadFloatBE(msBuffer buf, int64_t offset);
double msBufferReadDoubleLE(msBuffer buf, int64_t offset);
double msBufferReadDoubleBE(msBuffer buf, int64_t offset);
int64_t msBufferWriteFloatLE(msBuffer buf, double value, int64_t offset);
int64_t msBufferWriteFloatBE(msBuffer buf, double value, int64_t offset);
int64_t msBufferWriteDoubleLE(msBuffer buf, double value, int64_t offset);
int64_t msBufferWriteDoubleBE(msBuffer buf, double value, int64_t offset);

/* ===== 64-bit Integers ===== */

int64_t msBufferReadUint64LE(msBuffer buf, int64_t offset);
int64_t msBufferReadUint64BE(msBuffer buf, int64_t offset);
int64_t msBufferReadInt64LE(msBuffer buf, int64_t offset);
int64_t msBufferReadInt64BE(msBuffer buf, int64_t offset);
int64_t msBufferWriteUint64LE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteUint64BE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteInt64LE(msBuffer buf, int64_t value, int64_t offset);
int64_t msBufferWriteInt64BE(msBuffer buf, int64_t value, int64_t offset);

/* ===== Single-Byte Search ===== */

int64_t msBufferIndexOf(msBuffer buf, int64_t value, int64_t byteOffset);
int64_t msBufferLastIndexOf(msBuffer buf, int64_t value, int64_t byteOffset);

/* ===== Byte Swap ===== */

msBuffer msBufferSwap16(msBuffer buf);
msBuffer msBufferSwap32(msBuffer buf);
msBuffer msBufferSwap64(msBuffer buf);

/* ===== Reverse (in-place mutation) ===== */

msBuffer msBufferReverse(msBuffer buf);

/* ===== Validation ===== */

int64_t msBufferIsAscii(msBuffer buf);
int64_t msBufferIsUtf8(msBuffer buf);

/* ===== Advanced Search (Boyer-Moore Horspool) ===== */

int64_t msBufferIndexOfBuffer(msBuffer buf, msBuffer needle, int64_t byteOffset);
int64_t msBufferLastIndexOfBuffer(msBuffer buf, msBuffer needle, int64_t byteOffset);

/* ===== Encoding-Aware String Operations ===== */

int64_t msBufferWriteString(msBuffer buf, msString str, int64_t offset, int64_t length, msString encoding);

/* ===== Variable-Length Integer Read/Write (1-6 bytes) ===== */

int64_t msBufferReadUintLE(msBuffer buf, int64_t offset, int64_t byteLength);
int64_t msBufferReadUintBE(msBuffer buf, int64_t offset, int64_t byteLength);
int64_t msBufferReadIntLE(msBuffer buf, int64_t offset, int64_t byteLength);
int64_t msBufferReadIntBE(msBuffer buf, int64_t offset, int64_t byteLength);
int64_t msBufferWriteUintLE(msBuffer buf, int64_t value, int64_t offset, int64_t byteLength);
int64_t msBufferWriteUintBE(msBuffer buf, int64_t value, int64_t offset, int64_t byteLength);
int64_t msBufferWriteIntLE(msBuffer buf, int64_t value, int64_t offset, int64_t byteLength);
int64_t msBufferWriteIntBE(msBuffer buf, int64_t value, int64_t offset, int64_t byteLength);

/* ===== Fill String / Buffer ===== */

msBuffer msBufferFillString(msBuffer buf, msString value, int64_t start, int64_t end, msString encoding);
msBuffer msBufferFillBuffer(msBuffer buf, msBuffer pattern, int64_t start, int64_t end);

/* ===== toString with encoding + range ===== */

msString msBufferToStringRange(msBuffer buf, int64_t start, int64_t end, msString encoding);

#endif
