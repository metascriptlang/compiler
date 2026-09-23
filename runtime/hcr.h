#ifndef MS_HCR_H
#define MS_HCR_H

#include <stdlib.h>
#include <stdio.h>

#if defined(_WIN32)
#include <stdint.h>
#include <windows.h>
#define MS_HCR_EXPORT __declspec(dllexport)
static inline void* msHcrWinOpen(const char* path) {
	char full[MAX_PATH];
	DWORD length = GetFullPathNameA(path, MAX_PATH, full, NULL);
	if (length == 0 || length >= MAX_PATH) return NULL;
	return (void*)LoadLibraryExA(full, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
}
static inline void* msHcrWinNull(void) { return NULL; }
static inline void* msHcrWinSymbol(void* handle, const char* name) { return (void*)GetProcAddress((HMODULE)handle, name); }
static inline int32_t msHcrWinClose(void* handle) { return FreeLibrary((HMODULE)handle) ? 1 : 0; }
static inline uint32_t msHcrWinLastError(void) { return (uint32_t)GetLastError(); }
static inline int32_t msHcrWinIsNull(void* value) { return value == NULL ? 1 : 0; }
static inline uint64_t msHcrWinAddress(void* value) { return (uint64_t)(uintptr_t)value; }
static inline void* msHcrWinCallHandover(void* raw, void* state) { return ((void* (*)(void*))raw)(state); }
static inline void msHcrWinCallInit(void* raw) { ((void (*)(void))raw)(); }
static inline int32_t msHcrWinCallProbe(void* raw) { return ((int32_t (*)(void))raw)(); }
#else
#define MS_HCR_EXPORT __attribute__((visibility("default")))
#endif

#include <stdint.h>

typedef struct MsHcrHandle {
	void* const* current;
	uint32_t slotCount;
} MsHcrHandle;

MsHcrHandle* msHcrHandle(const char* moduleId);
void msHcrPublish(const char* moduleId, void* const* table, uint32_t slotCount);
void* msHcrTypeInfo(const char* moduleId, const char* typeName);
void msHcrCoreInit(void);

#endif
