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

/* POSIX realpath resolves symlinks; _fullpath only normalizes the spelling.
 * The final path comes from the opened file itself. When it names the same
 * spelling up to case, no link was crossed and the caller's spelling stays. */
static char* _msFsFinalPath(const char* full) {
	int wlen = MultiByteToWideChar(CP_UTF8, 0, full, -1, NULL, 0);
	if (wlen <= 0) return NULL;
	wchar_t* wfull = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)wlen);
	if (wfull == NULL) return NULL;
	MultiByteToWideChar(CP_UTF8, 0, full, -1, wfull, wlen);
	HANDLE h = CreateFileW(wfull, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
		NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
	free(wfull);
	if (h == INVALID_HANDLE_VALUE) return NULL;
	DWORD need = GetFinalPathNameByHandleW(h, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
	wchar_t* wfinal = need > 0 ? (wchar_t*)malloc(sizeof(wchar_t) * (size_t)(need + 1)) : NULL;
	DWORD got = wfinal != NULL ? GetFinalPathNameByHandleW(h, wfinal, need + 1, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS) : 0;
	CloseHandle(h);
	if (got == 0 || got > need) { if (wfinal) free(wfinal); return NULL; }
	const wchar_t* w = wfinal;
	wchar_t* unc = NULL;
	if (wcsncmp(w, L"\\\\?\\UNC\\", 8) == 0) {
		unc = (wchar_t*)malloc(sizeof(wchar_t) * (wcslen(w) - 6 + 1));
		if (unc == NULL) { free(wfinal); return NULL; }
		unc[0] = L'\\';
		wcscpy(unc + 1, w + 7);
		w = unc;
	} else if (wcsncmp(w, L"\\\\?\\", 4) == 0) {
		w = w + 4;
	}
	int ulen = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
	char* out = ulen > 0 ? (char*)malloc((size_t)ulen) : NULL;
	if (out != NULL) WideCharToMultiByte(CP_UTF8, 0, w, -1, out, ulen, NULL, NULL);
	if (unc) free(unc);
	free(wfinal);
	return out;
}

msString msFsRealPath(msString path) {
	char* full = _fullpath(NULL, msStringToCString(path), 0);
	if (!full) return MS_EMPTY_STRING;
	struct _stat st;
	if (_stat(full, &st) != 0) { free(full); return MS_EMPTY_STRING; }
	char* final = _msFsFinalPath(full);
	msString result = msStringFromCStr(final != NULL && _stricmp(final, full) != 0 ? final : full);
	if (final) free(final);
	free(full);
	return result;
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
	/* CRT rename() on Windows fails with EEXIST when the target exists —
	 * POSIX rename() atomically REPLACES it. MoveFileExW(REPLACE_EXISTING)
	 * is the Win32 spelling of that contract (Node's fs.rename does the
	 * same); posix.c keeps CRT rename, which already replaces there.
	 * Fails with ACCESS_DENIED while a reader holds the target open
	 * without FILE_SHARE_DELETE — callers that must not lose retry. */
	const char* oldUtf8 = msStringToCString(oldPath);
	const char* newUtf8 = msStringToCString(newPath);
	const int oldWLen = MultiByteToWideChar(CP_UTF8, 0, oldUtf8, -1, NULL, 0);
	const int newWLen = MultiByteToWideChar(CP_UTF8, 0, newUtf8, -1, NULL, 0);
	if (oldWLen <= 0 || newWLen <= 0) {
		_msFsLastErrno = ERROR_INVALID_PARAMETER;
		return 0.0;
	}
	wchar_t* oldW = (wchar_t*)malloc((size_t)oldWLen * sizeof(wchar_t));
	wchar_t* newW = (wchar_t*)malloc((size_t)newWLen * sizeof(wchar_t));
	if (oldW == NULL || newW == NULL) {
		if (oldW != NULL) free(oldW);
		if (newW != NULL) free(newW);
		_msFsLastErrno = ERROR_NOT_ENOUGH_MEMORY;
		return 0.0;
	}
	MultiByteToWideChar(CP_UTF8, 0, oldUtf8, -1, oldW, oldWLen);
	MultiByteToWideChar(CP_UTF8, 0, newUtf8, -1, newW, newWLen);
	const BOOL moved = MoveFileExW(oldW, newW, MOVEFILE_REPLACE_EXISTING);
	free(oldW);
	free(newW);
	if (moved) return 1.0;
	const DWORD gle = GetLastError();
	switch (gle) {
	case ERROR_FILE_NOT_FOUND:
	case ERROR_PATH_NOT_FOUND:
		_msFsLastErrno = ENOENT; break;
	case ERROR_ACCESS_DENIED:
		_msFsLastErrno = EACCES; break;
	case ERROR_INVALID_PARAMETER:
		_msFsLastErrno = EINVAL; break;
	case ERROR_NOT_ENOUGH_MEMORY:
		_msFsLastErrno = ENOMEM; break;
	default:
		_msFsLastErrno = EIO; break;
	}
	return 0.0;
}

/* end of windows.c */

double msFsSymlink(msString target, msString path) {
	_msFsLastErrno = 0;
	const char* targetUtf8 = msStringToCString(target);
	const char* pathUtf8 = msStringToCString(path);
	const int targetWLen = MultiByteToWideChar(CP_UTF8, 0, targetUtf8, -1, NULL, 0);
	const int pathWLen = MultiByteToWideChar(CP_UTF8, 0, pathUtf8, -1, NULL, 0);
	if (targetWLen <= 0 || pathWLen <= 0) {
		_msFsLastErrno = ERROR_INVALID_PARAMETER;
		return 0.0;
	}
	wchar_t* targetW = (wchar_t*)malloc((size_t)targetWLen * sizeof(wchar_t));
	wchar_t* pathW = (wchar_t*)malloc((size_t)pathWLen * sizeof(wchar_t));
	if (targetW == NULL || pathW == NULL) {
		if (targetW != NULL) free(targetW);
		if (pathW != NULL) free(pathW);
		_msFsLastErrno = ERROR_NOT_ENOUGH_MEMORY;
		return 0.0;
	}
	MultiByteToWideChar(CP_UTF8, 0, targetUtf8, -1, targetW, targetWLen);
	MultiByteToWideChar(CP_UTF8, 0, pathUtf8, -1, pathW, pathWLen);
	for (wchar_t* p = targetW; *p; p++) {
		if (*p == L'/') *p = L'\\';
	}
	/* A relative target resolves against the link's directory, as on POSIX. */
	DWORD flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
	DWORD attrs = GetFileAttributesW(targetW);
	if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
		flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
	}
	BOOL ok = CreateSymbolicLinkW(pathW, targetW, flags);
	if (!ok) _msFsLastErrno = (int)GetLastError();
	free(targetW);
	free(pathW);
	return ok ? 1.0 : 0.0;
}
