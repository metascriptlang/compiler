#ifndef HCR_FIXTURE_ENGINE_HOST_CALLS_H
#define HCR_FIXTURE_ENGINE_HOST_CALLS_H

#include "runtime/hcrEngine.h"

static inline void hcrFixtureLaunch(void* raw, const char* dir, const char* stem) {
	((void (*)(const char*, const char*))raw)(dir, stem);
}
static inline int32_t hcrFixtureStart(void* raw) { return ((int32_t (*)(void))raw)(); }

#endif
