/*
 * MetaScript File System Runtime — Windows implementation
 *
 * readFile and readDir; std/fs/index.cms calls the CRT and Win32 for the rest.
 * Selected by compile.ms when --os=windows.
 */
#include "runtime/fs/header.h"
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

static _Thread_local int _msFsLastErrno = 0;

int32_t msFsLastErrno(void) {
	return (int32_t)_msFsLastErrno;
}

/* ===== Read ===== */

msString msFsReadFile(msString path) {
	_msFsLastErrno = 0;
	FILE* f = fopen(msStringToCString(path), "rb");
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
