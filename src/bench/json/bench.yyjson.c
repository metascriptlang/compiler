// The yyjson twin of bench.ms on its mutable document: a parse row reads the input and copies it into a mutable
// document, as yyjson builds no mutable document from text directly; a stringify row writes a mutable document. The
// typed rows match bench.node.mjs: decode is the parse plus a read of every field the struct decode fills, encode
// writes the parsed document. Built by run.sh with the yyjson sources named by MSBENCH_YYJSON.

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "yyjson.h"

typedef struct { char *p; size_t len, cap; } Text;

static void put(Text *t, const char *fmt, ...) {
	va_list ap;
	for (;;) {
		va_start(ap, fmt);
		int n = vsnprintf(t->p + t->len, t->cap - t->len, fmt, ap);
		va_end(ap);
		if ((size_t)n < t->cap - t->len) { t->len += (size_t)n; return; }
		t->cap = t->cap * 2 + (size_t)n + 64;
		t->p = realloc(t->p, t->cap);
	}
}

static Text fresh(void) { Text t = { malloc(256), 0, 256 }; t.p[0] = 0; return t; }

static void item(Text *t, int i) {
	const int doubled = i * 37 % 200;
	put(t, "{\"id\":%d,\"name\":\"User %d\",\"email\":\"user%d@example.com\",\"active\":%s,", i, i, i, i % 3 == 0 ? "true" : "false");
	if (doubled % 2 == 0) put(t, "\"score\":%d,", doubled / 2); else put(t, "\"score\":%d.5,", doubled / 2);
	put(t, "\"tags\":[\"t%d\",\"t%d\",\"t%d\"],", i % 7, i % 11, i % 13);
	put(t, "\"address\":{\"street\":\"%d Market Street\",\"city\":\"City %d\",\"zip\":\"%d\"}}", i, i % 50, 10000 + i);
}

static Text payload(int count) {
	Text t = fresh();
	put(&t, "{\"page\":1,\"total\":%d,\"items\":[", count);
	for (int i = 0; i < count; i++) { if (i > 0) put(&t, ","); item(&t, i); }
	put(&t, "]}");
	return t;
}

static Text numbers(int count) {
	Text t = fresh();
	put(&t, "[");
	for (int i = 0; i < count; i++) {
		const long whole = (long)i * 7919 % 1000003 - 500000;
		if (i > 0) put(&t, ",");
		if (i % 2 == 0) put(&t, "%ld", whole); else put(&t, "%ld.%d", whole, i * 13 % 1000 + 1);
	}
	put(&t, "]");
	return t;
}

static Text strings(int count) {
	Text t = fresh();
	put(&t, "[");
	for (int i = 0; i < count; i++) {
		if (i > 0) put(&t, ",");
		put(&t, "\"line %d \\\"quoted\\\" C:\\\\path\\n\\ttab caf\\u00e9 \\u4e2d\\u6587 \\ud83d\\ude00 end\"", i);
	}
	put(&t, "]");
	return t;
}

// The checksum of bench.ms over UTF-16 units, so the check lines compare with the other arms.
static void checksum(char *out, const char *s, size_t len) {
	uint64_t hash = 0, units = 0;
	for (size_t i = 0; i < len;) {
		const unsigned char c = (unsigned char)s[i];
		uint32_t cp; size_t w;
		if (c < 0x80) { cp = c; w = 1; }
		else if (c < 0xE0) { cp = c & 0x1F; w = 2; }
		else if (c < 0xF0) { cp = c & 0x0F; w = 3; }
		else { cp = c & 0x07; w = 4; }
		for (size_t k = 1; k < w; k++) cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
		i += w;
		if (cp >= 0x10000) {
			cp -= 0x10000;
			hash = (hash * 31 + (0xD800 + (cp >> 10))) % 1000000007;
			hash = (hash * 31 + (0xDC00 + (cp & 0x3FF))) % 1000000007;
			units += 2;
		} else {
			hash = (hash * 31 + cp) % 1000000007;
			units += 1;
		}
	}
	sprintf(out, "%llu:%llu", (unsigned long long)units, (unsigned long long)hash);
}

static double sink = 0;

static yyjson_mut_doc *parsed(const Text *t) {
	yyjson_doc *doc = yyjson_read(t->p, t->len, 0);
	if (doc == NULL) { fprintf(stderr, "parse failed\n"); exit(1); }
	yyjson_mut_doc *mut = yyjson_doc_mut_copy(doc, NULL);
	yyjson_doc_free(doc);
	return mut;
}

static size_t rootSize(yyjson_mut_doc *doc) {
	yyjson_mut_val *root = yyjson_mut_doc_get_root(doc);
	return yyjson_mut_is_arr(root) ? yyjson_mut_arr_size(root) : yyjson_mut_obj_size(root);
}

static size_t written(yyjson_mut_doc *doc) {
	size_t len = 0;
	char *out = yyjson_mut_write(doc, 0, &len);
	free(out);
	return len;
}

static double strLen(yyjson_mut_val *v) { return (double)yyjson_mut_get_len(v); }

static yyjson_mut_doc *decoded(const Text *t) {
	yyjson_mut_doc *doc = parsed(t);
	yyjson_mut_val *root = yyjson_mut_doc_get_root(doc);
	double fields = yyjson_mut_get_num(yyjson_mut_obj_get(root, "page")) + yyjson_mut_get_num(yyjson_mut_obj_get(root, "total"));
	yyjson_mut_val *items = yyjson_mut_obj_get(root, "items");
	size_t idx, max;
	yyjson_mut_val *it;
	yyjson_mut_arr_foreach(items, idx, max, it) {
		fields += yyjson_mut_get_num(yyjson_mut_obj_get(it, "id")) + strLen(yyjson_mut_obj_get(it, "name")) +
			strLen(yyjson_mut_obj_get(it, "email")) + (yyjson_mut_get_bool(yyjson_mut_obj_get(it, "active")) ? 1 : 0) +
			yyjson_mut_get_num(yyjson_mut_obj_get(it, "score"));
		size_t ti, tmax;
		yyjson_mut_val *tag;
		yyjson_mut_arr_foreach(yyjson_mut_obj_get(it, "tags"), ti, tmax, tag) fields += strLen(tag);
		yyjson_mut_val *address = yyjson_mut_obj_get(it, "address");
		fields += strLen(yyjson_mut_obj_get(address, "street")) + strLen(yyjson_mut_obj_get(address, "city")) +
			strLen(yyjson_mut_obj_get(address, "zip"));
	}
	sink += fields;
	return doc;
}

static double nowMs(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

typedef void (*Op)(void);

static double round1(Op op) {
	double calls = 1;
	for (;;) {
		const double start = nowMs();
		for (double i = 0; i < calls; i++) op();
		const double elapsed = nowMs() - start;
		if (elapsed >= 250.0) return elapsed / calls;
		calls = elapsed < 1.0 ? calls * 16 : ceil(calls * (250.0 * 1.2 / elapsed));
	}
}

static int byRate(const void *a, const void *b) {
	const double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static void bench(const char *name, double perCallBytes, Op op) {
	double rates[3];
	for (int r = 0; r < 3; r++) {
		const double ms = round1(op);
		rates[r] = perCallBytes > 0 ? perCallBytes / ms / 1000.0 : ms * 1000.0;
	}
	qsort(rates, 3, sizeof(double), byRate);
	char value[32];
	snprintf(value, sizeof value, "%.3f %s", rates[1], perCallBytes > 0 ? "MB/s" : "us/op");
	printf("%-28s%-18sspread %.1f%%\n", name, value, (rates[2] - rates[0]) / rates[1] * 100.0);
}

static Text small, medium, large, nums, strs;
static yyjson_mut_doc *smallTree, *mediumTree, *largeTree, *numbersTree, *stringsTree, *mediumTyped;

static void parseOf(const Text *t) { yyjson_mut_doc *d = parsed(t); sink += (double)rootSize(d); yyjson_mut_doc_free(d); }
static void parseSmall(void) { parseOf(&small); }
static void parseMedium(void) { parseOf(&medium); }
static void parseLarge(void) { parseOf(&large); }
static void parseNumbers(void) { parseOf(&nums); }
static void parseStrings(void) { parseOf(&strs); }
static void writeSmall(void) { sink += (double)written(smallTree); }
static void writeMedium(void) { sink += (double)written(mediumTree); }
static void writeLarge(void) { sink += (double)written(largeTree); }
static void writeNumbers(void) { sink += (double)written(numbersTree); }
static void writeStrings(void) { sink += (double)written(stringsTree); }
static void decodeTyped(void) {
	yyjson_mut_doc *d = decoded(&medium);
	yyjson_mut_val *items = yyjson_mut_obj_get(yyjson_mut_doc_get_root(d), "items");
	const size_t n = yyjson_mut_arr_size(items);
	sink += (double)n + yyjson_mut_get_num(yyjson_mut_obj_get(yyjson_mut_arr_get(items, n - 1), "id"));
	yyjson_mut_doc_free(d);
}
static void encodeTyped(void) { sink += (double)written(mediumTyped); }

static void sumOf(char *out, yyjson_mut_doc *doc) {
	size_t len = 0;
	char *text = yyjson_mut_write(doc, 0, &len);
	checksum(out, text, len);
	free(text);
}

int main(void) {
	small = fresh(); item(&small, 4242);
	medium = payload(360);
	large = payload(5700);
	nums = numbers(7100);
	strs = strings(820);
	smallTree = parsed(&small); mediumTree = parsed(&medium); largeTree = parsed(&large);
	numbersTree = parsed(&nums); stringsTree = parsed(&strs); mediumTyped = decoded(&medium);

	char a[40], b[40], c[40], d[40], e[40], f[40];
	sumOf(a, smallTree); sumOf(b, mediumTree); sumOf(c, largeTree); sumOf(d, numbersTree); sumOf(e, stringsTree); sumOf(f, mediumTyped);
	fprintf(stderr, "check inputs %zu %zu %zu %zu %zu\n", small.len, medium.len, large.len, nums.len, strs.len);
	fprintf(stderr, "check stringify %s %s %s %s %s\n", a, b, c, d, e);
	fprintf(stderr, "check typed %s\n", f);

	bench("parse small object", 0, parseSmall);
	bench("parse medium 64 KB", (double)medium.len, parseMedium);
	bench("parse large 1 MB", (double)large.len, parseLarge);
	bench("parse numbers 64 KB", (double)nums.len, parseNumbers);
	bench("parse strings 64 KB", (double)strs.len, parseStrings);
	bench("stringify small object", 0, writeSmall);
	bench("stringify medium 64 KB", (double)medium.len, writeMedium);
	bench("stringify large 1 MB", (double)large.len, writeLarge);
	bench("stringify numbers 64 KB", (double)nums.len, writeNumbers);
	bench("stringify strings 64 KB", (double)strs.len, writeStrings);
	bench("decode typed medium 64 KB", (double)medium.len, decodeTyped);
	bench("encode typed medium 64 KB", (double)medium.len, encodeTyped);

	if (sink < 0) printf("unreachable %f\n", sink);
	return 0;
}
