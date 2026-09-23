#ifndef MS_HCR_ENGINE_H
#define MS_HCR_ENGINE_H

#include "runtime/hcr.h"
#include "runtime/core/string.h"

void msHcrLaunch(const char* dir, const char* stem);
msString msHcrLaunchDir(void);
msString msHcrLaunchStem(void);

static inline msString msHcrCallText(void* raw) { return msStringFromCStr(((const char* (*)(void))raw)()); }

static inline int32_t msHcrImportCount(void* raw) {
	const char* const* imports = ((const char* const* (*)(void))raw)();
	int32_t count = 0;
	while (imports[count * 2] != NULL) count += 1;
	return count;
}

static inline msString msHcrImportId(void* raw, int32_t index) {
	return msStringFromCStr(((const char* const* (*)(void))raw)()[index * 2]);
}

static inline msString msHcrImportKey(void* raw, int32_t index) {
	return msStringFromCStr(((const char* const* (*)(void))raw)()[index * 2 + 1]);
}

#if defined(_WIN32)
static inline uint64_t msHcrFileIdentity(const char* path) {
	WIN32_FILE_ATTRIBUTE_DATA data;
	if (!GetFileAttributesExA(path, GetFileExInfoStandard, &data)) return 0;
	uint64_t written = ((uint64_t)data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
	uint64_t size = ((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow;
	return (written * 1000003ULL) ^ size ^ 1ULL;
}
static inline uint32_t msHcrCopyImage(const char* from, const char* to) {
	return CopyFileA(from, to, FALSE) ? 0 : (uint32_t)GetLastError();
}
static inline int32_t msHcrMakeDir(const char* path) {
	return (CreateDirectoryA(path, NULL) || GetLastError() == ERROR_ALREADY_EXISTS) ? 1 : 0;
}
static inline uint32_t msHcrProcessId(void) { return (uint32_t)GetCurrentProcessId(); }
#else
static inline void msHcrEngineUnsupported(void) {
	fprintf(stderr, "HCR: the reload engine has no loader for this platform yet\n");
	abort();
}
static inline uint64_t msHcrFileIdentity(const char* path) { (void)path; msHcrEngineUnsupported(); return 0; }
static inline uint32_t msHcrCopyImage(const char* from, const char* to) { (void)from; (void)to; msHcrEngineUnsupported(); return 0; }
static inline int32_t msHcrMakeDir(const char* path) { (void)path; msHcrEngineUnsupported(); return 0; }
static inline uint32_t msHcrProcessId(void) { msHcrEngineUnsupported(); return 0; }
static inline void* msHcrWinOpen(const char* path) { (void)path; msHcrEngineUnsupported(); return NULL; }
static inline void* msHcrWinSymbol(void* handle, const char* name) { (void)handle; (void)name; msHcrEngineUnsupported(); return NULL; }
static inline int32_t msHcrWinClose(void* handle) { (void)handle; msHcrEngineUnsupported(); return 0; }
static inline uint32_t msHcrWinLastError(void) { msHcrEngineUnsupported(); return 0; }
static inline int32_t msHcrWinIsNull(void* value) { return value == NULL ? 1 : 0; }
static inline void* msHcrWinNull(void) { return NULL; }
static inline void* msHcrWinCallHandover(void* raw, void* state) { return ((void* (*)(void*))raw)(state); }
static inline void msHcrWinCallInit(void* raw) { ((void (*)(void))raw)(); }
#endif

#endif
