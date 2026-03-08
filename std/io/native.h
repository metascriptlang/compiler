/**
 * MetaScript I/O Runtime (C Backend)
 *
 * Provides stdin/stdout/stderr operations.
 */

#ifndef MS_STD_IO_H
#define MS_STD_IO_H

#include <stdio.h>
#include "system.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Read a line from stdin (up to newline or EOF).
 * Returns empty string on EOF.
 */
static inline msString msReadLine(void) {
	char buf[4096];
	if (fgets(buf, sizeof(buf), stdin) == NULL) {
		return MS_EMPTY_STRING;
	}
	/* Strip trailing \r\n or \n (LSP uses \r\n framing) */
	size_t len = strlen(buf);
	if (len > 0 && buf[len - 1] == '\n') {
		buf[--len] = '\0';
	}
	if (len > 0 && buf[len - 1] == '\r') {
		buf[--len] = '\0';
	}
	return msStringFromCStr(buf);
}

/**
 * Read exactly n bytes from stdin, retrying on short reads (pipes).
 * Returns what was read (fewer only on EOF/error).
 */
static inline msString msReadBytes(double n) {
	int64_t count = (int64_t)n;
	if (count <= 0) return MS_EMPTY_STRING;
	if (count > 1048576) count = 1048576; /* 1 MiB cap */
	char* buf = (char*)malloc(count + 1);
	if (!buf) return MS_EMPTY_STRING;
	size_t total = 0;
	while (total < (size_t)count) {
		size_t nread = fread(buf + total, 1, count - total, stdin);
		if (nread == 0) break; /* EOF or error */
		total += nread;
	}
	buf[total] = '\0';
	msString result = msStringNew(buf, (int64_t)total);
	free(buf);
	return result;
}

/**
 * Read entire file contents. Returns empty string on error.
 */
static inline msString msReadFile(msString path) {
	FILE* f = fopen(msCStr(path), "rb");
	if (!f) return MS_EMPTY_STRING;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz <= 0 || sz > 10485760) { fclose(f); return MS_EMPTY_STRING; }
	char* buf = (char*)malloc(sz + 1);
	if (!buf) { fclose(f); return MS_EMPTY_STRING; }
	size_t nread = fread(buf, 1, sz, f);
	fclose(f);
	buf[nread] = '\0';
	msString result = msStringNew(buf, (int64_t)nread);
	free(buf);
	return result;
}

/**
 * Extract a JSON string field value using raw char pointers (no per-char allocation).
 * Scans for "field":"value" pattern. Returns unescaped value or empty string.
 */
static inline msString msJsonGetField(msString json, msString field) {
	const char* js = msCStr(json);
	int64_t jsLen = json.len;
	const char* fld = msCStr(field);
	int64_t fldLen = field.len;

	/* Build pattern: "field": */
	for (int64_t i = 0; i + fldLen + 3 <= jsLen; i++) {
		if (js[i] == '"' && memcmp(js + i + 1, fld, fldLen) == 0 && js[i + 1 + fldLen] == '"' && js[i + 2 + fldLen] == ':') {
			int64_t j = i + 3 + fldLen;
			/* Skip whitespace */
			while (j < jsLen && (js[j] == ' ' || js[j] == '\t')) j++;
			if (j >= jsLen || js[j] != '"') continue;
			j++; /* skip opening quote */

			/* Scan for closing quote, check for escapes */
			int hasEscapes = 0;
			int64_t endPos = j;
			while (endPos < jsLen) {
				if (js[endPos] == '\\') { hasEscapes = 1; endPos += 2; }
				else if (js[endPos] == '"') { break; }
				else { endPos++; }
			}

			if (!hasEscapes) {
				return msStringNew((char*)(js + j), endPos - j);
			}

			/* Has escapes: decode */
			int64_t maxLen = endPos - j;
			char* buf = (char*)malloc(maxLen + 1);
			if (!buf) return MS_EMPTY_STRING;
			int64_t out = 0;
			int64_t k = j;
			while (k < endPos) {
				if (js[k] == '\\' && k + 1 < endPos) {
					switch (js[k + 1]) {
						case '"':  buf[out++] = '"'; break;
						case '\\': buf[out++] = '\\'; break;
						case 'n':  buf[out++] = '\n'; break;
						case 'r':  buf[out++] = '\r'; break;
						case 't':  buf[out++] = '\t'; break;
						case '/':  buf[out++] = '/'; break;
						default:   buf[out++] = js[k + 1]; break;
					}
					k += 2;
				} else {
					buf[out++] = js[k++];
				}
			}
			buf[out] = '\0';
			msString result = msStringNew(buf, out);
			free(buf);
			return result;
		}
	}
	return MS_EMPTY_STRING;
}

/**
 * Extract a JSON number field value. Returns -1 if not found.
 */
static inline double msJsonGetNumberField(msString json, msString field) {
	const char* js = msCStr(json);
	int64_t jsLen = json.len;
	const char* fld = msCStr(field);
	int64_t fldLen = field.len;

	for (int64_t i = 0; i + fldLen + 3 <= jsLen; i++) {
		if (js[i] == '"' && memcmp(js + i + 1, fld, fldLen) == 0 && js[i + 1 + fldLen] == '"' && js[i + 2 + fldLen] == ':') {
			int64_t j = i + 3 + fldLen;
			while (j < jsLen && (js[j] == ' ' || js[j] == '\t')) j++;
			int neg = 0;
			if (j < jsLen && js[j] == '-') { neg = 1; j++; }
			double result = 0;
			int found = 0;
			while (j < jsLen && js[j] >= '0' && js[j] <= '9') {
				result = result * 10 + (js[j] - '0');
				found = 1;
				j++;
			}
			if (!found) return -1;
			if (neg) result = -result;
			return result;
		}
	}
	return -1;
}

/**
 * Extract a nested JSON object for a key. Returns the {...} substring.
 */
static inline msString msJsonGetObjectField(msString json, msString field) {
	const char* js = msCStr(json);
	int64_t jsLen = json.len;
	const char* fld = msCStr(field);
	int64_t fldLen = field.len;

	for (int64_t i = 0; i + fldLen + 3 <= jsLen; i++) {
		if (js[i] == '"' && memcmp(js + i + 1, fld, fldLen) == 0 && js[i + 1 + fldLen] == '"' && js[i + 2 + fldLen] == ':') {
			int64_t j = i + 3 + fldLen;
			while (j < jsLen && (js[j] == ' ' || js[j] == '\t')) j++;
			if (j >= jsLen || js[j] != '{') continue;
			int depth = 0;
			int64_t start = j;
			while (j < jsLen) {
				char c = js[j];
				if (c == '{') { depth++; }
				else if (c == '}') { depth--; if (depth == 0) return msStringNew((char*)(js + start), j - start + 1); }
				else if (c == '"') { j++; while (j < jsLen && js[j] != '"') { if (js[j] == '\\') j++; j++; } }
				j++;
			}
		}
	}
	return MS_EMPTY_STRING;
}

/**
 * Write string to stdout, flushing immediately.
 */
static inline void msWriteStdout(msString s) {
	if (s.len > 0) {
		fwrite(msCStr(s), 1, s.len, stdout);
		fflush(stdout);
	}
}

/**
 * Write string to stderr, flushing immediately.
 */
static inline void msWriteStderr(msString s) {
	if (s.len > 0) {
		fwrite(msCStr(s), 1, s.len, stderr);
		fflush(stderr);
	}
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_IO_H */
