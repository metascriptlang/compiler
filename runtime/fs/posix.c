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
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>

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
	_msFsLastErrno = 0;
	if (chmod(msStringToCString(path), (mode_t)mode) != 0) {
		_msFsLastErrno = errno;
		return 0.0;
	}
	return 1.0;
}

/* ===== Stat ===== */

double msFsExists(msString path) {
	struct stat st;
	return (stat(msStringToCString(path), &st) == 0) ? 1.0 : 0.0;
}

double msFsIsFile(msString path) {
	struct stat st;
	if (stat(msStringToCString(path), &st) != 0) return 0.0;
	return S_ISREG(st.st_mode) ? 1.0 : 0.0;
}

double msFsIsDir(msString path) {
	struct stat st;
	if (stat(msStringToCString(path), &st) != 0) return 0.0;
	return S_ISDIR(st.st_mode) ? 1.0 : 0.0;
}

double msFsIsExecutable(msString path) {
	/* POSIX: access(X_OK) checks if current UID/GID has execute permission.
	 * Matches Bun.which's isExecutableFilePath and shutil.which behaviour. */
	return (access(msStringToCString(path), X_OK) == 0) ? 1.0 : 0.0;
}

double msFsFileSize(msString path) {
	struct stat st;
	if (stat(msStringToCString(path), &st) != 0) return -1.0;
	return (double)st.st_size;
}

/* ===== Directory ===== */

double msFsMkdir(msString path) {
	_msFsLastErrno = 0;
	int r = mkdir(msStringToCString(path), 0755);
	if (r == 0 || errno == EEXIST) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

double msFsRmdir(msString path) {
	_msFsLastErrno = 0;
	if (rmdir(msStringToCString(path)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

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
			char* tmp = (char*)malloc(pathLen + 1 + nlen + 1);
			if (tmp) {
				memcpy(tmp, cpath, pathLen);
				tmp[pathLen] = '/';
				memcpy(tmp + pathLen + 1, e->d_name, nlen);
				tmp[pathLen + 1 + nlen] = '\0';
				struct stat st;
				if (stat(tmp, &st) == 0 && S_ISDIR(st.st_mode)) {
					isDir = 1;
				}
				free(tmp);
			}
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

/* ===== Remove / Rename ===== */

double msFsRemove(msString path) {
	_msFsLastErrno = 0;
	if (unlink(msStringToCString(path)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

double msFsRename(msString oldPath, msString newPath) {
	_msFsLastErrno = 0;
	if (rename(msStringToCString(oldPath), msStringToCString(newPath)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

/* end of posix.c */
