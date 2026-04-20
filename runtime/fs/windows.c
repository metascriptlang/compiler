/*
 * MetaScript File System Runtime — Windows implementation
 *
 * Win32 API: FindFirstFileA, _mkdir, _stat, _unlink.
 * Selected by compile.ms when --os=windows.
 */
#include "runtime/fs/header.h"
#include <windows.h>
#include <direct.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>

/* MinGW compat */
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif

static int _msFsLastErrno = 0;

int32_t msFsLastErrno(void) {
	return (int32_t)_msFsLastErrno;
}

/* ===== Read ===== */

msString msFsReadFile(msString path) {
	_msFsLastErrno = 0;
	FILE* f = fopen(msStringToCString(path), "rb");
	if (!f) { _msFsLastErrno = errno; return MS_EMPTY_STRING; }
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz <= 0 || sz > 67108864) { fclose(f); return MS_EMPTY_STRING; }
	char* buf = (char*)malloc(sz + 1);
	if (!buf) { fclose(f); return MS_EMPTY_STRING; }
	size_t nread = fread(buf, 1, sz, f);
	fclose(f);
	buf[nread] = '\0';
	msString result = msStringNew(buf, (int64_t)nread);
	free(buf);
	return result;
}

/* ===== Write ===== */

double msFsWriteFileMode(msString path, msString content, msString mode) {
	_msFsLastErrno = 0;
	FILE* f = fopen(msStringToCString(path), msStringToCString(mode));
	if (!f) { _msFsLastErrno = errno; return 0.0; }
	size_t written = fwrite(msStringToCString(content), 1, content.len, f);
	fclose(f);
	return (written == (size_t)content.len) ? 1.0 : 0.0;
}

/* ===== Permissions ===== */

double msFsChmod(msString path, int32_t mode) {
	/* Windows ACL model — no-op, always succeed */
	(void)path; (void)mode;
	_msFsLastErrno = 0;
	return 1.0;
}

/* ===== Stat ===== */

double msFsExists(msString path) {
	struct _stat st;
	return (_stat(msStringToCString(path), &st) == 0) ? 1.0 : 0.0;
}

double msFsIsFile(msString path) {
	struct _stat st;
	if (_stat(msStringToCString(path), &st) != 0) return 0.0;
	return S_ISREG(st.st_mode) ? 1.0 : 0.0;
}

double msFsIsDir(msString path) {
	struct _stat st;
	if (_stat(msStringToCString(path), &st) != 0) return 0.0;
	return S_ISDIR(st.st_mode) ? 1.0 : 0.0;
}

double msFsIsExecutable(msString path) {
	/* Windows has no exec bit — an executable is defined by PATHEXT suffix.
	 * findOnPath enforces PATHEXT matching above us, so here we just confirm
	 * the path resolves to a regular file. Mirrors Bun.whichWin searchBin. */
	struct _stat st;
	if (_stat(msStringToCString(path), &st) != 0) return 0.0;
	return S_ISREG(st.st_mode) ? 1.0 : 0.0;
}

double msFsFileSize(msString path) {
	struct _stat st;
	if (_stat(msStringToCString(path), &st) != 0) return -1.0;
	return (double)st.st_size;
}

/* ===== Directory ===== */

double msFsMkdir(msString path) {
	_msFsLastErrno = 0;
	int r = _mkdir(msStringToCString(path));
	if (r == 0 || errno == EEXIST) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

double msFsRmdir(msString path) {
	_msFsLastErrno = 0;
	if (_rmdir(msStringToCString(path)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

msString msFsReadDirEntries(msString path) {
	_msFsLastErrno = 0;
	const char* cpath = msStringToCString(path);
	size_t pathLen = strlen(cpath);

	/* Build glob pattern: "path\\*" */
	char* pattern = (char*)malloc(pathLen + 3);
	if (!pattern) { _msFsLastErrno = ENOMEM; return MS_EMPTY_STRING; }
	memcpy(pattern, cpath, pathLen);
	if (pathLen > 0 && cpath[pathLen - 1] != '\\' && cpath[pathLen - 1] != '/') {
		pattern[pathLen] = '\\';
		pattern[pathLen + 1] = '*';
		pattern[pathLen + 2] = '\0';
	} else {
		pattern[pathLen] = '*';
		pattern[pathLen + 1] = '\0';
	}

	WIN32_FIND_DATAA fd;
	HANDLE h = FindFirstFileA(pattern, &fd);
	free(pattern);
	if (h == INVALID_HANDLE_VALUE) {
		_msFsLastErrno = (int)GetLastError();
		return MS_EMPTY_STRING;
	}

	size_t cap = 4096;
	size_t len = 0;
	char* buf = (char*)malloc(cap);
	if (!buf) { FindClose(h); _msFsLastErrno = ENOMEM; return MS_EMPTY_STRING; }

	do {
		/* Skip "." and ".." */
		if (fd.cFileName[0] == '.' &&
		    (fd.cFileName[1] == '\0' ||
		     (fd.cFileName[1] == '.' && fd.cFileName[2] == '\0'))) {
			continue;
		}
		size_t nlen = strlen(fd.cFileName);
		int isDir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
		/* Resize buffer if needed: name + optional "/" + "\n" */
		while (len + nlen + 2 >= cap) {
			size_t newCap = cap * 2;
			char* nb = (char*)realloc(buf, newCap);
			if (!nb) { free(buf); FindClose(h); _msFsLastErrno = ENOMEM; return MS_EMPTY_STRING; }
			buf = nb;
			cap = newCap;
		}
		memcpy(buf + len, fd.cFileName, nlen);
		len += nlen;
		if (isDir) buf[len++] = '/';
		buf[len++] = '\n';
	} while (FindNextFileA(h, &fd));
	FindClose(h);

	msString result = msStringNew(buf, (int64_t)len);
	free(buf);
	return result;
}

/* ===== Remove / Rename ===== */

double msFsRemove(msString path) {
	_msFsLastErrno = 0;
	if (_unlink(msStringToCString(path)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

double msFsRename(msString oldPath, msString newPath) {
	_msFsLastErrno = 0;
	if (rename(msStringToCString(oldPath), msStringToCString(newPath)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

/* end of windows.c */
