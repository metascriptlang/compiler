#ifndef MS_RAISER_BRIDGE_H
#define MS_RAISER_BRIDGE_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The ABI between the Raiser and a native module's generated bridges. A bridge reads its arguments
   from args[] and writes its result to *result, each a 64-bit word: an integer, the bits of a double,
   or the address of a NUL-terminated string valid until the bridge returns. sig names the classes, the
   arguments' then ':' and the result's: i integer or bool, f float, s C string (argument only), v none. */
typedef void (*MsRaiserBridgeFn)(const int64_t* args, int64_t* result);

typedef struct MsRaiserBridge {
	const char* name;
	const char* sig;
	MsRaiserBridgeFn fn;
} MsRaiserBridge;

#if defined(_WIN32)
#define MS_RAISER_BRIDGE_EXPORT __declspec(dllexport)
#else
#define MS_RAISER_BRIDGE_EXPORT __attribute__((visibility("default")))
#endif

static inline double msRaiserBridgeF64(int64_t bits) { double d; memcpy(&d, &bits, sizeof d); return d; }
static inline int64_t msRaiserBridgeBits(double d) { int64_t bits; memcpy(&bits, &d, sizeof bits); return bits; }

static inline int64_t msRaiserBridgeCount(void* table) {
	const MsRaiserBridge* t = (const MsRaiserBridge*)table;
	int64_t n = 0;
	while (t[n].name != NULL) n++;
	return n;
}
static inline const char* msRaiserBridgeName(void* table, int64_t i) { return ((const MsRaiserBridge*)table)[i].name; }
static inline const char* msRaiserBridgeSig(void* table, int64_t i) { return ((const MsRaiserBridge*)table)[i].sig; }
static inline void* msRaiserBridgeFnAt(void* table, int64_t i) { return (void*)((const MsRaiserBridge*)table)[i].fn; }
static inline void msRaiserBridgeCall(void* fn, int64_t* args, int64_t* result) { ((MsRaiserBridgeFn)fn)(args, result); }
static inline int64_t* msRaiserBridgeWords(int64_t n) { return (int64_t*)calloc((size_t)(n > 0 ? n : 1), sizeof(int64_t)); }
static inline void msRaiserBridgeSetText(int64_t* args, int64_t i, const char* text) {
	size_t n = strlen(text) + 1;
	char* copy = (char*)malloc(n);
	memcpy(copy, text, n);
	args[i] = (int64_t)(intptr_t)copy;
}
static inline void msRaiserBridgeFreeText(int64_t* args, int64_t i) {
	free((void*)(intptr_t)args[i]);
	args[i] = 0;
}

#endif
