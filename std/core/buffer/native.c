/*
 * MetaScript Buffer Runtime — C Implementation
 *
 * Binary data operations: alloc, create, convert, byte access,
 * slice/copy/fill, compare, read/write integers (LE/BE).
 *
 * msBuffer is typedef msString — same struct, different semantics.
 * Key: msBufferLength returns buf.len (true byte count).
 */

#include "native.h"
#include <stdlib.h>
#include <string.h>

/* ===== Endianness Detection ===== */

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  #define MS_BIG_ENDIAN 1
#else
  #define MS_BIG_ENDIAN 0
#endif

#if defined(__GNUC__) || defined(__clang__)
  #define BSWAP16(x) __builtin_bswap16(x)
  #define BSWAP32(x) __builtin_bswap32(x)
  #define BSWAP64(x) __builtin_bswap64(x)
#else
  #define BSWAP16(x) ((uint16_t)((((x) >> 8) & 0xFF) | (((x) & 0xFF) << 8)))
  #define BSWAP32(x) ((uint32_t)((((x) >> 24) & 0xFF) | (((x) >> 8) & 0xFF00) | (((x) & 0xFF00) << 8) | (((x) & 0xFF) << 24)))
  #define BSWAP64(x) ((uint64_t)(BSWAP32((uint32_t)(x)) ) << 32 | BSWAP32((uint32_t)((x) >> 32)))
#endif

/* ===== Hex/Base64 Helpers ===== */

static int hexCharToInt(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static const char hexTable[] = "0123456789abcdef";

static const char b64Chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int b64CharToInt(char c) {
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == '/') return 63;
	return -1;
}

/* ===== Allocation ===== */

msBuffer msBufferAlloc(int64_t size) {
	if (size <= 0) return MS_EMPTY_BUFFER;

	msStrPayload* p = (msStrPayload*)calloc(1, sizeof(msStrPayload) + size + 1);
	if (!p) return MS_EMPTY_BUFFER;

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

	msStrPayload* p = (msStrPayload*)malloc(sizeof(msStrPayload) + size + 1);
	if (!p) return MS_EMPTY_BUFFER;

	p->cap = size;
	p->data[size] = '\0';  /* null-terminate only */

	msBuffer buf;
	buf.len = size;
	buf.p = p;
	return buf;
}

/* ===== Creation ===== */

msBuffer msBufferFromString(msString str) {
	if (!str.p || str.len == 0) return MS_EMPTY_BUFFER;
	/* Deep copy — source may be a string literal (read-only COW memory) */
	msBuffer buf = msBufferAlloc(str.len);
	if (!buf.p) return MS_EMPTY_BUFFER;
	memcpy(buf.p->data, str.p->data, str.len);
	return buf;
}

msBuffer msBufferFromHex(msString hex) {
	if (!hex.p || hex.len < 2) return MS_EMPTY_BUFFER;

	int64_t byteLen = hex.len / 2;
	msBuffer buf = msBufferAlloc(byteLen);
	if (!buf.p) return MS_EMPTY_BUFFER;

	for (int64_t i = 0; i < byteLen; i++) {
		int hi = hexCharToInt(hex.p->data[i * 2]);
		int lo = hexCharToInt(hex.p->data[i * 2 + 1]);
		if (hi < 0 || lo < 0) {
			buf.p->data[i] = 0;
		} else {
			buf.p->data[i] = (char)((hi << 4) | lo);
		}
	}
	return buf;
}

msBuffer msBufferFromBase64(msString b64) {
	if (!b64.p || b64.len == 0) return MS_EMPTY_BUFFER;

	/* Calculate output size accounting for padding */
	int padding = 0;
	if (b64.len > 0 && b64.p->data[b64.len - 1] == '=') padding++;
	if (b64.len > 1 && b64.p->data[b64.len - 2] == '=') padding++;
	int64_t outLen = (b64.len * 3) / 4 - padding;

	msBuffer buf = msBufferAlloc(outLen);
	if (!buf.p) return MS_EMPTY_BUFFER;

	int64_t j = 0;
	for (int64_t i = 0; i < b64.len && j < outLen; i += 4) {
		int a = b64CharToInt(b64.p->data[i]);
		int b = (i + 1 < b64.len) ? b64CharToInt(b64.p->data[i + 1]) : 0;
		int c = (i + 2 < b64.len) ? b64CharToInt(b64.p->data[i + 2]) : 0;
		int d = (i + 3 < b64.len) ? b64CharToInt(b64.p->data[i + 3]) : 0;

		if (a < 0) a = 0;
		if (b < 0) b = 0;
		if (c < 0) c = 0;
		if (d < 0) d = 0;

		if (j < outLen) buf.p->data[j++] = (char)((a << 2) | (b >> 4));
		if (j < outLen) buf.p->data[j++] = (char)(((b & 0x0F) << 4) | (c >> 2));
		if (j < outLen) buf.p->data[j++] = (char)(((c & 0x03) << 6) | d);
	}
	return buf;
}

/* ===== Conversion ===== */

msString msBufferToHex(msBuffer buf) {
	if (!buf.p || buf.len == 0) return MS_EMPTY_STRING;

	int64_t hexLen = buf.len * 2;
	char* out = (char*)malloc(hexLen + 1);
	if (!out) return MS_EMPTY_STRING;

	for (int64_t i = 0; i < buf.len; i++) {
		unsigned char byte = (unsigned char)buf.p->data[i];
		out[i * 2] = hexTable[byte >> 4];
		out[i * 2 + 1] = hexTable[byte & 0x0F];
	}
	out[hexLen] = '\0';

	msString result = msStringNew(out, hexLen);
	free(out);
	return result;
}

msString msBufferToBase64(msBuffer buf) {
	if (!buf.p || buf.len == 0) return MS_EMPTY_STRING;

	int64_t outLen = ((buf.len + 2) / 3) * 4;
	char* out = (char*)malloc(outLen + 1);
	if (!out) return MS_EMPTY_STRING;

	int64_t j = 0;
	for (int64_t i = 0; i < buf.len; i += 3) {
		unsigned char b0 = (unsigned char)buf.p->data[i];
		unsigned char b1 = (i + 1 < buf.len) ? (unsigned char)buf.p->data[i + 1] : 0;
		unsigned char b2 = (i + 2 < buf.len) ? (unsigned char)buf.p->data[i + 2] : 0;

		out[j++] = b64Chars[b0 >> 2];
		out[j++] = b64Chars[((b0 & 0x03) << 4) | (b1 >> 4)];
		out[j++] = (i + 1 < buf.len) ? b64Chars[((b1 & 0x0F) << 2) | (b2 >> 6)] : '=';
		out[j++] = (i + 2 < buf.len) ? b64Chars[b2 & 0x3F] : '=';
	}
	out[outLen] = '\0';

	msString result = msStringNew(out, outLen);
	free(out);
	return result;
}

msString msBufferToString(msBuffer buf) {
	return buf;  /* identity */
}

/* ===== Properties ===== */

int64_t msBufferLength(msBuffer buf) {
	return buf.len;  /* true byte count — THE key difference from msStringLength */
}

/* ===== Byte Access ===== */

int64_t msBufferGet(msBuffer buf, int64_t index) {
	if (!buf.p || index < 0 || index >= buf.len) return -1;
	return (int64_t)(unsigned char)buf.p->data[index];
}

void msBufferSet(msBuffer buf, int64_t index, int64_t value) {
	if (!buf.p || index < 0 || index >= buf.len) return;
	buf.p->data[index] = (char)(value & 0xFF);
}

/* ===== Operations ===== */

msBuffer msBufferSlice(msBuffer buf, int64_t start, int64_t end) {
	if (!buf.p || start >= end || start >= buf.len) return MS_EMPTY_BUFFER;
	if (end > buf.len) end = buf.len;
	if (start < 0) start = 0;

	int64_t len = end - start;
	msBuffer result = msBufferAlloc(len);
	if (!result.p) return MS_EMPTY_BUFFER;

	memcpy(result.p->data, buf.p->data + start, len);
	return result;
}

int64_t msBufferCopy(msBuffer src, msBuffer dst, int64_t dstStart, int64_t srcStart, int64_t srcEnd) {
	if (!src.p || !dst.p) return 0;
	if (srcStart < 0) srcStart = 0;
	if (srcEnd > src.len) srcEnd = src.len;
	if (dstStart < 0) dstStart = 0;
	if (srcStart >= srcEnd) return 0;

	int64_t len = srcEnd - srcStart;
	if (dstStart + len > dst.len) len = dst.len - dstStart;
	if (len <= 0) return 0;

	memmove(dst.p->data + dstStart, src.p->data + srcStart, len);
	return len;
}

msBuffer msBufferFill(msBuffer buf, int64_t value, int64_t start, int64_t end) {
	if (!buf.p) return buf;
	if (start < 0) start = 0;
	if (end > buf.len) end = buf.len;
	if (start >= end) return buf;

	memset(buf.p->data + start, (int)(value & 0xFF), end - start);
	return buf;
}

msBuffer msBufferConcat(msBuffer a, msBuffer b) {
	if ((!a.p || a.len == 0) && (!b.p || b.len == 0)) return MS_EMPTY_BUFFER;
	if (!a.p || a.len == 0) return msBufferCopyNew(b);
	if (!b.p || b.len == 0) return msBufferCopyNew(a);

	int64_t totalLen = a.len + b.len;
	msBuffer result = msBufferAlloc(totalLen);
	if (!result.p) return MS_EMPTY_BUFFER;

	memcpy(result.p->data, a.p->data, a.len);
	memcpy(result.p->data + a.len, b.p->data, b.len);
	return result;
}

msBuffer msBufferCopyNew(msBuffer buf) {
	if (!buf.p || buf.len == 0) return MS_EMPTY_BUFFER;

	msBuffer copy = msBufferAlloc(buf.len);
	if (copy.p) {
		memcpy(copy.p->data, buf.p->data, buf.len);
	}
	return copy;
}

/* ===== Comparison ===== */

int64_t msBufferCompare(msBuffer a, msBuffer b) {
	if (!a.p && !b.p) return 0;
	if (!a.p) return -1;
	if (!b.p) return 1;

	int64_t minLen = (a.len < b.len) ? a.len : b.len;
	int cmp = memcmp(a.p->data, b.p->data, minLen);
	if (cmp != 0) return (int64_t)cmp;
	if (a.len < b.len) return -1;
	if (a.len > b.len) return 1;
	return 0;
}

int64_t msBufferEquals(msBuffer a, msBuffer b) {
	if (a.len != b.len) return 0;
	if (!a.p && !b.p) return 1;
	if (!a.p || !b.p) return 0;
	return memcmp(a.p->data, b.p->data, a.len) == 0 ? 1 : 0;
}

/* ===== Read Integers ===== */

int64_t msBufferReadUint8(msBuffer buf, int64_t offset) {
	if (!buf.p || offset < 0 || offset >= buf.len) return 0;
	return (int64_t)(unsigned char)buf.p->data[offset];
}

int64_t msBufferReadUint16LE(msBuffer buf, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 2 > buf.len) return 0;
	return (int64_t)(unsigned char)buf.p->data[o] |
	       ((int64_t)(unsigned char)buf.p->data[o + 1] << 8);
}

int64_t msBufferReadUint16BE(msBuffer buf, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 2 > buf.len) return 0;
	return ((int64_t)(unsigned char)buf.p->data[o] << 8) |
	       (int64_t)(unsigned char)buf.p->data[o + 1];
}

int64_t msBufferReadUint32LE(msBuffer buf, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 4 > buf.len) return 0;
	return (int64_t)(unsigned char)buf.p->data[o] |
	       ((int64_t)(unsigned char)buf.p->data[o + 1] << 8) |
	       ((int64_t)(unsigned char)buf.p->data[o + 2] << 16) |
	       ((int64_t)(unsigned char)buf.p->data[o + 3] << 24);
}

int64_t msBufferReadUint32BE(msBuffer buf, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 4 > buf.len) return 0;
	return ((int64_t)(unsigned char)buf.p->data[o] << 24) |
	       ((int64_t)(unsigned char)buf.p->data[o + 1] << 16) |
	       ((int64_t)(unsigned char)buf.p->data[o + 2] << 8) |
	       (int64_t)(unsigned char)buf.p->data[o + 3];
}

int64_t msBufferReadInt32LE(msBuffer buf, int64_t offset) {
	int64_t val = msBufferReadUint32LE(buf, offset);
	/* Sign-extend from 32 bits */
	if (val & 0x80000000LL) {
		val |= ~0xFFFFFFFFLL;
	}
	return val;
}

int64_t msBufferReadInt32BE(msBuffer buf, int64_t offset) {
	int64_t val = msBufferReadUint32BE(buf, offset);
	if (val & 0x80000000LL) {
		val |= ~0xFFFFFFFFLL;
	}
	return val;
}

/* ===== Write Integers ===== */

int64_t msBufferWriteUint8(msBuffer buf, int64_t value, int64_t offset) {
	if (!buf.p || offset < 0 || offset >= buf.len) return offset;
	buf.p->data[offset] = (char)(value & 0xFF);
	return offset + 1;
}

int64_t msBufferWriteUint16LE(msBuffer buf, int64_t value, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 2 > buf.len) return o;
	buf.p->data[o] = (char)(value & 0xFF);
	buf.p->data[o + 1] = (char)((value >> 8) & 0xFF);
	return o + 2;
}

int64_t msBufferWriteUint16BE(msBuffer buf, int64_t value, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 2 > buf.len) return o;
	buf.p->data[o] = (char)((value >> 8) & 0xFF);
	buf.p->data[o + 1] = (char)(value & 0xFF);
	return o + 2;
}

int64_t msBufferWriteUint32LE(msBuffer buf, int64_t value, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 4 > buf.len) return o;
	buf.p->data[o] = (char)(value & 0xFF);
	buf.p->data[o + 1] = (char)((value >> 8) & 0xFF);
	buf.p->data[o + 2] = (char)((value >> 16) & 0xFF);
	buf.p->data[o + 3] = (char)((value >> 24) & 0xFF);
	return o + 4;
}

int64_t msBufferWriteUint32BE(msBuffer buf, int64_t value, int64_t offset) {
	int64_t o = offset;
	if (!buf.p || o < 0 || o + 4 > buf.len) return o;
	buf.p->data[o] = (char)((value >> 24) & 0xFF);
	buf.p->data[o + 1] = (char)((value >> 16) & 0xFF);
	buf.p->data[o + 2] = (char)((value >> 8) & 0xFF);
	buf.p->data[o + 3] = (char)(value & 0xFF);
	return o + 4;
}

int64_t msBufferWriteInt32LE(msBuffer buf, int64_t value, int64_t offset) {
	return msBufferWriteUint32LE(buf, value, offset);
}

int64_t msBufferWriteInt32BE(msBuffer buf, int64_t value, int64_t offset) {
	return msBufferWriteUint32BE(buf, value, offset);
}

/* ===== Signed 8/16-bit Read ===== */

int64_t msBufferReadInt8(msBuffer buf, int64_t offset) {
	int64_t val = msBufferReadUint8(buf, offset);
	if (val & 0x80) val |= ~0xFFLL;
	return val;
}

int64_t msBufferReadInt16LE(msBuffer buf, int64_t offset) {
	int64_t val = msBufferReadUint16LE(buf, offset);
	if (val & 0x8000) val |= ~0xFFFFLL;
	return val;
}

int64_t msBufferReadInt16BE(msBuffer buf, int64_t offset) {
	int64_t val = msBufferReadUint16BE(buf, offset);
	if (val & 0x8000) val |= ~0xFFFFLL;
	return val;
}

/* ===== Signed 8/16-bit Write ===== */

int64_t msBufferWriteInt8(msBuffer buf, int64_t value, int64_t offset) {
	return msBufferWriteUint8(buf, value, offset);
}

int64_t msBufferWriteInt16LE(msBuffer buf, int64_t value, int64_t offset) {
	return msBufferWriteUint16LE(buf, value, offset);
}

int64_t msBufferWriteInt16BE(msBuffer buf, int64_t value, int64_t offset) {
	return msBufferWriteUint16BE(buf, value, offset);
}

/* ===== Float Read/Write ===== */

double msBufferReadFloatLE(msBuffer buf, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 4 > buf.len) return 0.0;
	uint32_t val;
	memcpy(&val, buf.p->data + offset, 4);
#if MS_BIG_ENDIAN
	val = BSWAP32(val);
#endif
	float f;
	memcpy(&f, &val, 4);
	return (double)f;
}

double msBufferReadFloatBE(msBuffer buf, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 4 > buf.len) return 0.0;
	uint32_t val;
	memcpy(&val, buf.p->data + offset, 4);
#if !MS_BIG_ENDIAN
	val = BSWAP32(val);
#endif
	float f;
	memcpy(&f, &val, 4);
	return (double)f;
}

int64_t msBufferWriteFloatLE(msBuffer buf, double value, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 4 > buf.len) return offset;
	float f = (float)value;
	uint32_t val;
	memcpy(&val, &f, 4);
#if MS_BIG_ENDIAN
	val = BSWAP32(val);
#endif
	memcpy(buf.p->data + offset, &val, 4);
	return offset + 4;
}

int64_t msBufferWriteFloatBE(msBuffer buf, double value, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 4 > buf.len) return offset;
	float f = (float)value;
	uint32_t val;
	memcpy(&val, &f, 4);
#if !MS_BIG_ENDIAN
	val = BSWAP32(val);
#endif
	memcpy(buf.p->data + offset, &val, 4);
	return offset + 4;
}

/* ===== Double Read/Write ===== */

double msBufferReadDoubleLE(msBuffer buf, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return 0.0;
	uint64_t val;
	memcpy(&val, buf.p->data + offset, 8);
#if MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	double d;
	memcpy(&d, &val, 8);
	return d;
}

double msBufferReadDoubleBE(msBuffer buf, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return 0.0;
	uint64_t val;
	memcpy(&val, buf.p->data + offset, 8);
#if !MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	double d;
	memcpy(&d, &val, 8);
	return d;
}

int64_t msBufferWriteDoubleLE(msBuffer buf, double value, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return offset;
	uint64_t val;
	memcpy(&val, &value, 8);
#if MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	memcpy(buf.p->data + offset, &val, 8);
	return offset + 8;
}

int64_t msBufferWriteDoubleBE(msBuffer buf, double value, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return offset;
	uint64_t val;
	memcpy(&val, &value, 8);
#if !MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	memcpy(buf.p->data + offset, &val, 8);
	return offset + 8;
}

/* ===== 64-bit Integer Read/Write ===== */

int64_t msBufferReadUint64LE(msBuffer buf, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return 0;
	uint64_t val;
	memcpy(&val, buf.p->data + offset, 8);
#if MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	return (int64_t)val;
}

int64_t msBufferReadUint64BE(msBuffer buf, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return 0;
	uint64_t val;
	memcpy(&val, buf.p->data + offset, 8);
#if !MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	return (int64_t)val;
}

int64_t msBufferReadInt64LE(msBuffer buf, int64_t offset) {
	return msBufferReadUint64LE(buf, offset);
}

int64_t msBufferReadInt64BE(msBuffer buf, int64_t offset) {
	return msBufferReadUint64BE(buf, offset);
}

int64_t msBufferWriteUint64LE(msBuffer buf, int64_t value, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return offset;
	uint64_t val = (uint64_t)value;
#if MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	memcpy(buf.p->data + offset, &val, 8);
	return offset + 8;
}

int64_t msBufferWriteUint64BE(msBuffer buf, int64_t value, int64_t offset) {
	if (!buf.p || offset < 0 || offset + 8 > buf.len) return offset;
	uint64_t val = (uint64_t)value;
#if !MS_BIG_ENDIAN
	val = BSWAP64(val);
#endif
	memcpy(buf.p->data + offset, &val, 8);
	return offset + 8;
}

int64_t msBufferWriteInt64LE(msBuffer buf, int64_t value, int64_t offset) {
	return msBufferWriteUint64LE(buf, value, offset);
}

int64_t msBufferWriteInt64BE(msBuffer buf, int64_t value, int64_t offset) {
	return msBufferWriteUint64BE(buf, value, offset);
}

/* ===== Search ===== */

int64_t msBufferIndexOf(msBuffer buf, int64_t value, int64_t byteOffset) {
	if (!buf.p || buf.len == 0) return -1;
	int64_t start = (byteOffset < 0) ? 0 : byteOffset;
	if (start >= buf.len) return -1;

	unsigned char needle = (unsigned char)(value & 0xFF);
	void* found = memchr(buf.p->data + start, needle, buf.len - start);
	if (found) return (int64_t)((char*)found - buf.p->data);
	return -1;
}

int64_t msBufferLastIndexOf(msBuffer buf, int64_t value, int64_t byteOffset) {
	if (!buf.p || buf.len == 0) return -1;
	int64_t end = (byteOffset < 0 || byteOffset >= buf.len) ? buf.len - 1 : byteOffset;
	unsigned char needle = (unsigned char)(value & 0xFF);

	for (int64_t i = end; i >= 0; i--) {
		if ((unsigned char)buf.p->data[i] == needle) return i;
	}
	return -1;
}

int64_t msBufferIncludes(msBuffer buf, int64_t value, int64_t byteOffset) {
	return msBufferIndexOf(buf, value, byteOffset) != -1 ? 1 : 0;
}

/* ===== Byte Swap ===== */

msBuffer msBufferSwap16(msBuffer buf) {
	if (!buf.p || buf.len % 2 != 0) return MS_EMPTY_BUFFER;
	uint16_t* data = (uint16_t*)buf.p->data;
	int64_t count = buf.len / 2;
	for (int64_t i = 0; i < count; i++) {
		data[i] = BSWAP16(data[i]);
	}
	return buf;
}

msBuffer msBufferSwap32(msBuffer buf) {
	if (!buf.p || buf.len % 4 != 0) return MS_EMPTY_BUFFER;
	uint32_t* data = (uint32_t*)buf.p->data;
	int64_t count = buf.len / 4;
	for (int64_t i = 0; i < count; i++) {
		data[i] = BSWAP32(data[i]);
	}
	return buf;
}

msBuffer msBufferSwap64(msBuffer buf) {
	if (!buf.p || buf.len % 8 != 0) return MS_EMPTY_BUFFER;
	uint64_t* data = (uint64_t*)buf.p->data;
	int64_t count = buf.len / 8;
	for (int64_t i = 0; i < count; i++) {
		data[i] = BSWAP64(data[i]);
	}
	return buf;
}

/* ===== Reverse ===== */

msBuffer msBufferReverse(msBuffer buf) {
	if (!buf.p || buf.len <= 1) return buf;
	char* data = buf.p->data;
	int64_t left = 0;
	int64_t right = buf.len - 1;
	while (left < right) {
		char tmp = data[left];
		data[left] = data[right];
		data[right] = tmp;
		left++;
		right--;
	}
	return buf;
}

/* ===== Validation ===== */

int64_t msBufferIsAscii(msBuffer buf) {
	if (!buf.p || buf.len == 0) return 1;
	const unsigned char* data = (const unsigned char*)buf.p->data;
	for (int64_t i = 0; i < buf.len; i++) {
		if (data[i] > 127) return 0;
	}
	return 1;
}

int64_t msBufferIsUtf8(msBuffer buf) {
	if (!buf.p || buf.len == 0) return 1;
	const unsigned char* data = (const unsigned char*)buf.p->data;
	int64_t i = 0;
	while (i < buf.len) {
		unsigned char c = data[i];
		if (c <= 0x7F) {
			i++;
		} else if ((c & 0xE0) == 0xC0) {
			if (i + 1 >= buf.len || (data[i + 1] & 0xC0) != 0x80) return 0;
			if (c < 0xC2) return 0;
			i += 2;
		} else if ((c & 0xF0) == 0xE0) {
			if (i + 2 >= buf.len) return 0;
			if ((data[i + 1] & 0xC0) != 0x80 || (data[i + 2] & 0xC0) != 0x80) return 0;
			uint32_t cp = ((c & 0x0F) << 12) | ((data[i + 1] & 0x3F) << 6) | (data[i + 2] & 0x3F);
			if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
			i += 3;
		} else if ((c & 0xF8) == 0xF0) {
			if (i + 3 >= buf.len) return 0;
			if ((data[i + 1] & 0xC0) != 0x80 || (data[i + 2] & 0xC0) != 0x80 || (data[i + 3] & 0xC0) != 0x80) return 0;
			uint32_t cp = ((c & 0x07) << 18) | ((data[i + 1] & 0x3F) << 12) | ((data[i + 2] & 0x3F) << 6) | (data[i + 3] & 0x3F);
			if (cp < 0x10000 || cp > 0x10FFFF) return 0;
			i += 4;
		} else {
			return 0;
		}
	}
	return 1;
}
