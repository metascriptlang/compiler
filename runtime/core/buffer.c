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

/* ===== Creation ===== */

/* ===== Encoding ===== */

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
	char* out = (char*)msMemAlloc(hexLen + 1);

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
	char* out = (char*)msMemAlloc(outLen + 1);

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

/* ===== Encoding Helper ===== */

static int encodingEq(const char* enc, int64_t encLen, const char* target) {
	int tlen = (int)strlen(target);
	if (encLen < tlen) return 0;
	for (int i = 0; i < tlen; i++) {
		char c = enc[i];
		if (c >= 'A' && c <= 'Z') c += 32;
		if (c != target[i]) return 0;
	}
	return 1;
}

/* ===== Hex/Base64 String Write ===== */

int64_t msBufferWriteString(msBuffer buf, msString str, int64_t offset, int64_t length, msString encoding) {
	if (!buf.p || !str.p || str.len == 0) return 0;
	if (offset < 0 || offset >= buf.len) return 0;

	int64_t maxLen = (length < 0) ? (buf.len - offset) : length;
	if (offset + maxLen > buf.len) {
		maxLen = buf.len - offset;
	}

	const char* enc = encoding.p ? encoding.p->data : NULL;
	int64_t encLen = encoding.len;

	if (encodingEq(enc, encLen, "hex")) {
		int64_t hexPairs = str.len / 2;
		int64_t toWrite = (hexPairs < maxLen) ? hexPairs : maxLen;
		for (int64_t i = 0; i < toWrite; i++) {
			int hi = hexCharToInt(str.p->data[i * 2]);
			int lo = hexCharToInt(str.p->data[i * 2 + 1]);
			buf.p->data[offset + i] = (hi < 0 || lo < 0) ? 0 : (char)((hi << 4) | lo);
		}
		return toWrite;
	}

	if (encodingEq(enc, encLen, "base64") || encodingEq(enc, encLen, "base64url")) {
		int padding = 0;
		if (str.len > 0 && str.p->data[str.len - 1] == '=') padding++;
		if (str.len > 1 && str.p->data[str.len - 2] == '=') padding++;
		int64_t outLen = (str.len * 3) / 4 - padding;
		int64_t toWrite = (outLen < maxLen) ? outLen : maxLen;

		int64_t j = 0;
		for (int64_t i = 0; i < str.len && j < toWrite; i += 4) {
			int a = b64CharToInt(str.p->data[i]);
			int b = (i + 1 < str.len) ? b64CharToInt(str.p->data[i + 1]) : 0;
			int c = (i + 2 < str.len) ? b64CharToInt(str.p->data[i + 2]) : 0;
			int d = (i + 3 < str.len) ? b64CharToInt(str.p->data[i + 3]) : 0;
			if (a < 0) a = 0; if (b < 0) b = 0; if (c < 0) c = 0; if (d < 0) d = 0;
			if (j < toWrite) buf.p->data[offset + j++] = (char)((a << 2) | (b >> 4));
			if (j < toWrite) buf.p->data[offset + j++] = (char)(((b & 0x0F) << 4) | (c >> 2));
			if (j < toWrite) buf.p->data[offset + j++] = (char)(((c & 0x03) << 6) | d);
		}
		return j;
	}

	return 0;
}

/* ===== toString with encoding + range ===== */

msString msBufferToStringRange(msBuffer buf, int64_t start, int64_t end, msString encoding) {
	if (!buf.p || buf.len == 0) return MS_EMPTY_STRING;
	if (start < 0) start = 0;
	if (end < 0 || end > buf.len) end = buf.len;
	if (start >= end) return MS_EMPTY_STRING;

	int64_t len = end - start;
	const char* enc = encoding.p ? encoding.p->data : NULL;
	int64_t encLen = encoding.len;

	if (!enc || encLen == 0 || encodingEq(enc, encLen, "utf8") || encodingEq(enc, encLen, "utf-8")) {
		return msStringFromUtf8Lossy(buf.p->data + start, len);
	}
	if (encodingEq(enc, encLen, "latin1") || encodingEq(enc, encLen, "binary")) {
		return msStringFromLatin1(buf.p->data + start, len);
	}

	if (encodingEq(enc, encLen, "ascii")) {
		char* out = (char*)msMemAlloc(len + 1);
		for (int64_t i = 0; i < len; i++) {
			out[i] = buf.p->data[start + i] & 0x7F;
		}
		out[len] = '\0';
		msString result = msStringNew(out, len);
		free(out);
		return result;
	}

	if (encodingEq(enc, encLen, "hex")) {
		int64_t hexLen = len * 2;
		char* out = (char*)msMemAlloc(hexLen + 1);
		for (int64_t i = 0; i < len; i++) {
			unsigned char byte = (unsigned char)buf.p->data[start + i];
			out[i * 2] = hexTable[byte >> 4];
			out[i * 2 + 1] = hexTable[byte & 0x0F];
		}
		out[hexLen] = '\0';
		msString result = msStringNew(out, hexLen);
		free(out);
		return result;
	}

	if (encodingEq(enc, encLen, "base64") || encodingEq(enc, encLen, "base64url")) {
		int64_t outLen = ((len + 2) / 3) * 4;
		char* out = (char*)msMemAlloc(outLen + 1);
		int64_t j = 0;
		for (int64_t i = 0; i < len; i += 3) {
			unsigned char b0 = (unsigned char)buf.p->data[start + i];
			unsigned char b1 = (i + 1 < len) ? (unsigned char)buf.p->data[start + i + 1] : 0;
			unsigned char b2 = (i + 2 < len) ? (unsigned char)buf.p->data[start + i + 2] : 0;
			out[j++] = b64Chars[b0 >> 2];
			out[j++] = b64Chars[((b0 & 0x03) << 4) | (b1 >> 4)];
			out[j++] = (i + 1 < len) ? b64Chars[((b1 & 0x0F) << 2) | (b2 >> 6)] : '=';
			out[j++] = (i + 2 < len) ? b64Chars[b2 & 0x3F] : '=';
		}
		out[outLen] = '\0';
		msString result = msStringNew(out, outLen);
		free(out);
		return result;
	}

	/* Default: utf8 */
	return msStringFromUtf8Lossy(buf.p->data + start, len);
}
