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

static inline msString msHcrFailureText(void) { return msStringFromCStr(msHcrImageFailure()); }
static inline msString msHcrImageExt(void) { return msStringFromCStr(MS_HCR_IMAGE_EXT); }

#if defined(_WIN32)
static inline uint64_t msHcrFileIdentity(const char* path) {
	WIN32_FILE_ATTRIBUTE_DATA data;
	if (!GetFileAttributesExA(path, GetFileExInfoStandard, &data)) return 0;
	uint64_t written = ((uint64_t)data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
	uint64_t size = ((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow;
	return (written * 1000003ULL) ^ size ^ 1ULL;
}
static inline int32_t msHcrCopyImage(const char* from, const char* to) {
	if (CopyFileA(from, to, FALSE)) return 1;
	msHcrImageRecordFailure();
	return 0;
}
static inline int32_t msHcrMakeDir(const char* path) {
	if (CreateDirectoryA(path, NULL) || GetLastError() == ERROR_ALREADY_EXISTS) return 1;
	msHcrImageRecordFailure();
	return 0;
}
static inline uint32_t msHcrProcessId(void) { return (uint32_t)GetCurrentProcessId(); }
#else
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static inline void msHcrRecordErrno(const char* what, const char* path) {
	snprintf(msHcrImageFailureText, sizeof(msHcrImageFailureText), "%s %s: %s", what, path, strerror(errno));
}
static inline uint64_t msHcrFileIdentity(const char* path) {
	struct stat info;
	if (stat(path, &info) != 0) return 0;
#if defined(__APPLE__)
	uint64_t written = (uint64_t)info.st_mtimespec.tv_sec * 1000000000ULL + (uint64_t)info.st_mtimespec.tv_nsec;
#else
	uint64_t written = (uint64_t)info.st_mtim.tv_sec * 1000000000ULL + (uint64_t)info.st_mtim.tv_nsec;
#endif
	return (written * 1000003ULL) ^ (uint64_t)info.st_size ^ 1ULL;
}
static inline int32_t msHcrCopyImage(const char* from, const char* to) {
	int in = open(from, O_RDONLY | O_CLOEXEC);
	if (in < 0) { msHcrRecordErrno("cannot open", from); return 0; }
	int out = open(to, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0755);
	if (out < 0) { msHcrRecordErrno("cannot create", to); close(in); return 0; }
	char buffer[65536];
	for (;;) {
		ssize_t got = read(in, buffer, sizeof(buffer));
		if (got == 0) break;
		if (got < 0) { msHcrRecordErrno("cannot read", from); close(in); close(out); return 0; }
		for (ssize_t done = 0; done < got;) {
			ssize_t wrote = write(out, buffer + done, (size_t)(got - done));
			if (wrote < 0) { msHcrRecordErrno("cannot write", to); close(in); close(out); return 0; }
			done += wrote;
		}
	}
	close(in);
	if (close(out) != 0) { msHcrRecordErrno("cannot write", to); return 0; }
	return 1;
}
static inline int32_t msHcrMakeDir(const char* path) {
	if (mkdir(path, 0755) == 0 || errno == EEXIST) return 1;
	msHcrRecordErrno("cannot create", path);
	return 0;
}
static inline uint32_t msHcrProcessId(void) { return (uint32_t)getpid(); }
#endif

#endif
