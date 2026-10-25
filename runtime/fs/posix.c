/*
 * MetaScript File System Runtime — POSIX implementation
 *
 * macOS, Linux, FreeBSD, etc. Uses stat/opendir/readdir/unlink/mkdir/chmod.
 * Selected by compile.ms when --os != windows.
 */
#include "runtime/fs/header.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
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
	if (fseeko(f, 0, SEEK_END) != 0) { _msFsLastErrno = errno; fclose(f); return MS_EMPTY_STRING; }
	off_t sz = ftello(f);
	if (sz < 0 || fseeko(f, 0, SEEK_SET) != 0) { _msFsLastErrno = errno; fclose(f); return MS_EMPTY_STRING; }
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

/* ===== Directory ===== */

msString msFsReadDirEntries(msString path) {
	_msFsLastErrno = 0;
	const char* cpath = msStringToCString(path);
	DIR* d = opendir(cpath);
	if (!d) {
		_msFsLastErrno = errno;
		return MS_EMPTY_STRING;
	}
	size_t cap = 4096;
	size_t len = 0;
	char* buf = (char*)malloc(cap);
	if (!buf) {
		closedir(d);
		_msFsLastErrno = ENOMEM;
		return MS_EMPTY_STRING;
	}
	size_t pathLen = strlen(cpath);
	struct dirent* e;
	while ((e = readdir(d)) != NULL) {
		/* Skip "." and ".." */
		if (e->d_name[0] == '.' &&
		    (e->d_name[1] == '\0' ||
		     (e->d_name[1] == '.' && e->d_name[2] == '\0'))) {
			continue;
		}
		size_t nlen = strlen(e->d_name);
		int isDir = 0;
#ifdef DT_DIR
		if (e->d_type == DT_DIR) {
			isDir = 1;
		} else if (e->d_type == DT_UNKNOWN || e->d_type == DT_LNK) {
#endif
			/* Fall back to stat: build "path/name" and check S_ISDIR */
			char* tmp = (char*)msMemAlloc(pathLen + 1 + nlen + 1);
			memcpy(tmp, cpath, pathLen);
			tmp[pathLen] = '/';
			memcpy(tmp + pathLen + 1, e->d_name, nlen);
			tmp[pathLen + 1 + nlen] = '\0';
			struct stat st;
			if (stat(tmp, &st) == 0 && S_ISDIR(st.st_mode)) {
				isDir = 1;
			}
			free(tmp);
#ifdef DT_DIR
		}
#endif
		/* Resize buffer if needed: name + optional "/" + "\n" */
		while (len + nlen + 2 >= cap) {
			size_t newCap = cap * 2;
			char* nb = (char*)realloc(buf, newCap);
			if (!nb) {
				free(buf);
				closedir(d);
				_msFsLastErrno = ENOMEM;
				return MS_EMPTY_STRING;
			}
			buf = nb;
			cap = newCap;
		}
		memcpy(buf + len, e->d_name, nlen);
		len += nlen;
		if (isDir) buf[len++] = '/';
		buf[len++] = '\n';
	}
	closedir(d);
	msString result = msStringNew(buf, (int64_t)len);
	free(buf);
	return result;
}

/* end of posix.c */
