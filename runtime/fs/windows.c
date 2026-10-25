/*
 * MetaScript File System Runtime — Windows implementation
 *
 * readFile and readDir; std/fs/index.cms calls the CRT and Win32 for the rest.
 * Paths arrive as UTF-8 and reach the wide entry points.
 * Selected by compile.ms when --os=windows.
 */
#include "runtime/fs/header.h"
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int32_t msFsErrnoFromWin32(uint32_t code) {
	switch (code) {
	case ERROR_FILE_NOT_FOUND:
	case ERROR_PATH_NOT_FOUND:
	case ERROR_INVALID_DRIVE:
	case ERROR_BAD_NETPATH:
	case ERROR_BAD_NET_NAME:
		return ENOENT;
	case ERROR_DIRECTORY:
		return ENOTDIR;
	case ERROR_ACCESS_DENIED:
		return EACCES;
	case ERROR_ALREADY_EXISTS:
	case ERROR_FILE_EXISTS:
		return EEXIST;
	case ERROR_DIR_NOT_EMPTY:
		return ENOTEMPTY;
	case ERROR_INVALID_PARAMETER:
	case ERROR_INVALID_NAME:
	case ERROR_BAD_PATHNAME:
		return EINVAL;
	case ERROR_FILENAME_EXCED_RANGE:
		return ENAMETOOLONG;
	case ERROR_NOT_ENOUGH_MEMORY:
	case ERROR_OUTOFMEMORY:
		return ENOMEM;
	case ERROR_DISK_FULL:
	case ERROR_HANDLE_DISK_FULL:
		return ENOSPC;
	case ERROR_NOT_SAME_DEVICE:
		return EXDEV;
	case ERROR_TOO_MANY_OPEN_FILES:
		return EMFILE;
	case ERROR_WRITE_PROTECT:
		return EROFS;
	case ERROR_FILE_TOO_LARGE:
		return EFBIG;
	case ERROR_BUSY:
		return EBUSY;
	default:
		return EIO;
	}
}

static _Thread_local int _msFsLastErrno = 0;

static wchar_t* msFsWidePath(msString path, int extra) {
	const char* cpath = msStringToCString(path);
	int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, cpath, -1, NULL, 0);
	if (n <= 0) { _msFsLastErrno = EINVAL; return NULL; }
	wchar_t* wide = (wchar_t*)malloc(((size_t)n + (size_t)extra) * sizeof(wchar_t));
	if (!wide) { _msFsLastErrno = ENOMEM; return NULL; }
	MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, cpath, -1, wide, n);
	return wide;
}

int32_t msFsLastErrno(void) {
	return (int32_t)_msFsLastErrno;
}

/* ===== Read ===== */

msString msFsReadFile(msString path) {
	_msFsLastErrno = 0;
	wchar_t* wide = msFsWidePath(path, 0);
	if (!wide) return MS_EMPTY_STRING;
	FILE* f = _wfopen(wide, L"rb");
	int openErrno = errno;
	free(wide);
	errno = openErrno;
	if (!f) { _msFsLastErrno = errno; return MS_EMPTY_STRING; }
	if (_fseeki64(f, 0, SEEK_END) != 0) { _msFsLastErrno = errno; fclose(f); return MS_EMPTY_STRING; }
	__int64 sz = _ftelli64(f);
	if (sz < 0 || _fseeki64(f, 0, SEEK_SET) != 0) { _msFsLastErrno = errno; fclose(f); return MS_EMPTY_STRING; }
	if (sz == 0) { fclose(f); return MS_EMPTY_STRING; }
	if (sz > MS_LEN_MAX) { _msFsLastErrno = EFBIG; fclose(f); return MS_EMPTY_STRING; }
	char* buf = (char*)malloc((size_t)sz + 1);
	if (!buf) { _msFsLastErrno = ENOMEM; fclose(f); return MS_EMPTY_STRING; }
	errno = 0;
	size_t nread = fread(buf, 1, (size_t)sz, f);
	if (nread != (size_t)sz && ferror(f)) {
		_msFsLastErrno = errno != 0 ? errno : EIO;
		free(buf);
		fclose(f);
		return MS_EMPTY_STRING;
	}
	fclose(f);
	buf[nread] = '\0';
	msString result = msStringNew(buf, (int64_t)nread);
	free(buf);
	return result;
}

msString msFsReadDirEntries(msString path) {
	_msFsLastErrno = 0;
	/* Build glob pattern: "path\\*" */
	wchar_t* pattern = msFsWidePath(path, 2);
	if (!pattern) return MS_EMPTY_STRING;
	size_t pathLen = wcslen(pattern);
	if (pathLen > 0 && pattern[pathLen - 1] != L'\\' && pattern[pathLen - 1] != L'/') {
		pattern[pathLen++] = L'\\';
	}
	pattern[pathLen] = L'*';
	pattern[pathLen + 1] = L'\0';

	WIN32_FIND_DATAW fd;
	HANDLE h = FindFirstFileW(pattern, &fd);
	free(pattern);
	if (h == INVALID_HANDLE_VALUE) {
		_msFsLastErrno = msFsErrnoFromWin32(GetLastError());
		return MS_EMPTY_STRING;
	}

	size_t cap = 4096;
	size_t len = 0;
	char* buf = (char*)malloc(cap);
	if (!buf) { FindClose(h); _msFsLastErrno = ENOMEM; return MS_EMPTY_STRING; }

	do {
		/* Skip "." and ".." */
		if (fd.cFileName[0] == L'.' &&
		    (fd.cFileName[1] == L'\0' ||
		     (fd.cFileName[1] == L'.' && fd.cFileName[2] == L'\0'))) {
			continue;
		}
		int nlen = WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, NULL, 0, NULL, NULL) - 1;
		if (nlen < 0) { free(buf); FindClose(h); _msFsLastErrno = EINVAL; return MS_EMPTY_STRING; }
		int isDir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
		/* Resize buffer if needed: name + optional "/" + "\n" */
		while (len + nlen + 2 >= cap) {
			size_t newCap = cap * 2;
			char* nb = (char*)realloc(buf, newCap);
			if (!nb) { free(buf); FindClose(h); _msFsLastErrno = ENOMEM; return MS_EMPTY_STRING; }
			buf = nb;
			cap = newCap;
		}
		WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, buf + len, nlen + 1, NULL, NULL);
		len += (size_t)nlen;
		if (isDir) buf[len++] = '/';
		buf[len++] = '\n';
	} while (FindNextFileW(h, &fd));
	FindClose(h);

	msString result = msStringNew(buf, (int64_t)len);
	free(buf);
	return result;
}
