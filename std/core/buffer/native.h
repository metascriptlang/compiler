/*
 * MetaScript Buffer Runtime
 * Binary data type — byte-oriented operations without UTF-8 interpretation.
 *
 * msBuffer = typedef msString (zero-cost, same 16-byte struct)
 * Key difference: msBufferLength returns buf.len (byte count),
 * while msStringLength counts UTF-16 code units.
 */

#ifndef MS_BUFFER_H
#define MS_BUFFER_H

#include "std/core/string/native.h"

/* ===== Core Type ===== */

typedef msString msBuffer;
#define MS_EMPTY_BUFFER MS_EMPTY_STRING

/* ===== Allocation ===== */

/* Zero-filled buffer of given size */
msBuffer msBufferAlloc(int64_t size);

/* Uninitialized buffer (only null-terminated) */
msBuffer msBufferAllocUnsafe(int64_t size);

/* ===== Creation ===== */

/* Wrap a string as buffer (identity — same type) */
msBuffer msBufferFromString(msString str);

/* Decode hex string to bytes */
msBuffer msBufferFromHex(msString hex);

/* Decode base64 string to bytes */
msBuffer msBufferFromBase64(msString b64);

/* ===== Conversion ===== */

/* Encode bytes to lowercase hex string */
msString msBufferToHex(msBuffer buf);

/* Encode bytes to base64 string */
msString msBufferToBase64(msBuffer buf);

/* Return as string (identity) */
msString msBufferToString(msBuffer buf);

/* ===== Properties ===== */

/* Byte count (buf.len — NOT UTF-16 code units) */
int64_t msBufferLength(msBuffer buf);

/* ===== Byte Access ===== */

/* Read byte at index (0-255), or -1 if out of bounds */
int64_t msBufferGet(msBuffer buf, int64_t index);

/* Write byte at index, no-op if out of bounds */
void msBufferSet(msBuffer buf, int64_t index, int64_t value);

/* ===== Operations ===== */

/* Extract sub-buffer [start, end) */
msBuffer msBufferSlice(msBuffer buf, int64_t start, int64_t end);

/* Copy bytes from src to dst. Returns bytes copied. */
int64_t msBufferCopy(msBuffer src, msBuffer dst, int64_t dstStart, int64_t srcStart, int64_t srcEnd);

/* Fill range [start, end) with byte value */
msBuffer msBufferFill(msBuffer buf, int64_t value, int64_t start, int64_t end);

/* Concatenate two buffers */
msBuffer msBufferConcat(msBuffer a, msBuffer b);

/* Deep copy */
msBuffer msBufferCopyNew(msBuffer buf);

/* ===== Comparison ===== */

/* memcmp-style: negative, 0, or positive */
int64_t msBufferCompare(msBuffer a, msBuffer b);

/* Content equality */
int64_t msBufferEquals(msBuffer a, msBuffer b);

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

/* ===== Search ===== */

int64_t msBufferIndexOf(msBuffer buf, int64_t value, int64_t byteOffset);
int64_t msBufferLastIndexOf(msBuffer buf, int64_t value, int64_t byteOffset);
int64_t msBufferIncludes(msBuffer buf, int64_t value, int64_t byteOffset);

/* ===== Byte Swap ===== */

msBuffer msBufferSwap16(msBuffer buf);
msBuffer msBufferSwap32(msBuffer buf);
msBuffer msBufferSwap64(msBuffer buf);

/* ===== Reverse ===== */

msBuffer msBufferReverse(msBuffer buf);

/* ===== Validation ===== */

int64_t msBufferIsAscii(msBuffer buf);
int64_t msBufferIsUtf8(msBuffer buf);

#endif
