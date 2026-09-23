#ifndef HCR_FIXTURE_HOST_CALLS_H
#define HCR_FIXTURE_HOST_CALLS_H

#include <string.h>
#include "runtime/hcr.h"

static inline void* hcrFixtureCore(void) { return (void*)GetModuleHandleA("module.core.dll"); }
static inline void hcrFixtureCallName(void* raw, const char* name) { ((void (*)(const char*))raw)(name); }
static inline int32_t hcrFixtureCallNameInt(void* raw, const char* name) { return ((int32_t (*)(const char*))raw)(name); }

static inline int32_t hcrFixtureImportMatches(void* importsRaw, const char* moduleId, void* keyRaw) {
	const char* const* imports = ((const char* const* (*)(void))importsRaw)();
	const char* key = ((const char* (*)(void))keyRaw)();
	for (int i = 0; imports[i] != NULL; i += 2) {
		if (strcmp(imports[i], moduleId) == 0) return strcmp(imports[i + 1], key) == 0 ? 1 : 0;
	}
	return -1;
}

#endif
