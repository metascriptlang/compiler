#ifndef HCR_FIXTURE_HOST_CALLS_H
#define HCR_FIXTURE_HOST_CALLS_H

#include <string.h>
#include "runtime/hcr.h"
#include "runtime/core/string.h"

#if defined(_WIN32)
static inline void* hcrFixtureCore(void) { return (void*)GetModuleHandleA("module.core" MS_HCR_IMAGE_EXT); }
#else
static inline void* hcrFixtureCore(void) { return dlopen("module.core" MS_HCR_IMAGE_EXT, RTLD_NOW | RTLD_NOLOAD); }
#endif
static inline msString hcrFixtureImageExt(void) { return msStringFromCStr(MS_HCR_IMAGE_EXT); }
static inline void hcrFixtureCallName(void* raw, const char* name) { ((void (*)(const char*))raw)(name); }
static inline int32_t hcrFixtureCallNameInt(void* raw, const char* name) { return ((int32_t (*)(const char*))raw)(name); }

static inline int32_t hcrFixtureHasBinding(const char* const* exports, const char* name, const char* key) {
	for (int i = 0; exports[i] != NULL; i += 2) {
		if (strcmp(exports[i], name) == 0 && strcmp(exports[i + 1], key) == 0) return 1;
	}
	return 0;
}

static inline int32_t hcrFixtureBindingsMatch(void* bindingsRaw, const char* moduleId, void* functionsRaw, void* variablesRaw) {
	const char* const* bindings = ((const char* const* (*)(void))bindingsRaw)();
	const char* const* functions = ((const char* const* (*)(void))functionsRaw)();
	const char* const* variables = ((const char* const* (*)(void))variablesRaw)();
	int32_t found = -1;
	for (int i = 0; bindings[i] != NULL; i += 3) {
		if (strcmp(bindings[i], moduleId) != 0) continue;
		found = 1;
		if (!hcrFixtureHasBinding(functions, bindings[i + 1], bindings[i + 2]) &&
			!hcrFixtureHasBinding(variables, bindings[i + 1], bindings[i + 2])) return 0;
	}
	return found;
}

#endif
