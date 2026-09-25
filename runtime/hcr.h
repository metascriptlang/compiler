#ifndef MS_HCR_H
#define MS_HCR_H

#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>

static char msHcrImageFailureText[512];

#if defined(_WIN32)
#include <windows.h>
#define MS_HCR_EXPORT __declspec(dllexport)
#define MS_HCR_IMAGE_EXT ".dll"
static inline void msHcrImageRecordFailure(void) {
	snprintf(msHcrImageFailureText, sizeof(msHcrImageFailureText), "error %lu", (unsigned long)GetLastError());
}
static inline void* msHcrImageOpen(const char* path) {
	char full[MAX_PATH];
	DWORD length = GetFullPathNameA(path, MAX_PATH, full, NULL);
	void* handle = (length == 0 || length >= MAX_PATH) ? NULL : (void*)LoadLibraryExA(full, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
	if (handle == NULL) msHcrImageRecordFailure();
	return handle;
}
static inline void* msHcrImageSymbol(void* handle, const char* name) { return (void*)GetProcAddress((HMODULE)handle, name); }
static inline int32_t msHcrImageClose(void* handle) { return FreeLibrary((HMODULE)handle) ? 1 : 0; }
static inline uint32_t msHcrImageLastError(void) { return (uint32_t)GetLastError(); }
#else
#include <dlfcn.h>
#define MS_HCR_EXPORT __attribute__((visibility("default")))
#if defined(__APPLE__)
#define MS_HCR_IMAGE_EXT ".dylib"
#else
#define MS_HCR_IMAGE_EXT ".so"
#endif
static inline void* msHcrImageOpen(const char* path) {
	void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (handle == NULL) {
		const char* reason = dlerror();
		snprintf(msHcrImageFailureText, sizeof(msHcrImageFailureText), "%s", reason != NULL ? reason : "dlopen failed");
	}
	return handle;
}
static inline void* msHcrImageSymbol(void* handle, const char* name) { return dlsym(handle, name); }
static inline int32_t msHcrImageClose(void* handle) { return dlclose(handle) == 0 ? 1 : 0; }
#endif

static inline const char* msHcrImageFailure(void) { return msHcrImageFailureText; }
static inline void* msHcrImageNull(void) { return NULL; }
static inline int32_t msHcrImageIsNull(void* value) { return value == NULL ? 1 : 0; }
static inline uint64_t msHcrImageAddress(void* value) { return (uint64_t)(uintptr_t)value; }
static inline void* msHcrImageCallHandover(void* raw, void* state) { return ((void* (*)(void*))raw)(state); }
static inline void msHcrImageCallInit(void* raw) { ((void (*)(void))raw)(); }
static inline int32_t msHcrImageCallProbe(void* raw) { return ((int32_t (*)(void))raw)(); }

typedef struct MsHcrHandle {
	void* const* current;
	uint32_t slotCount;
	void* const* old;
	uint32_t oldCount;
	void* const* staged;
	uint32_t stagedCount;
} MsHcrHandle;

MsHcrHandle* msHcrHandle(const char* moduleId);
void msHcrPublish(const char* moduleId, void* const* table, uint32_t slotCount);
void msHcrStageBegin(void);
void msHcrStageEnd(void);
int32_t msHcrStaged(const char* moduleId);
void msHcrCommit(const char* moduleId);
void msHcrRollback(const char* moduleId);
void msHcrDiscard(const char* moduleId);
void* msHcrTypeInfo(const char* moduleId, const char* typeName);
void msHcrRestoreTypeInfos(const char* moduleId);
void msHcrCoreInit(void);

#endif
