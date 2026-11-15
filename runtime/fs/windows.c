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
	wchar_t* wide = (wchar_t*)msMemAlloc(((size_t)n + (size_t)extra) * sizeof(wchar_t));
	if (!wide) { _msFsLastErrno = ENOMEM; return NULL; }
	MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, cpath, -1, wide, n);
	return wide;
}

int32_t msFsLastErrno(void) {
	return (int32_t)_msFsLastErrno;
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
	msMemFree(pattern);
	if (h == INVALID_HANDLE_VALUE) {
		_msFsLastErrno = msFsErrnoFromWin32(GetLastError());
		return MS_EMPTY_STRING;
	}

	size_t cap = 4096;
	size_t len = 0;
	char* buf = (char*)msMemAlloc(cap);
	if (!buf) { FindClose(h); _msFsLastErrno = ENOMEM; return MS_EMPTY_STRING; }

	do {
		/* Skip "." and ".." */
		if (fd.cFileName[0] == L'.' &&
		    (fd.cFileName[1] == L'\0' ||
		     (fd.cFileName[1] == L'.' && fd.cFileName[2] == L'\0'))) {
			continue;
		}
		int nlen = WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, NULL, 0, NULL, NULL) - 1;
		if (nlen < 0) { msMemFree(buf); FindClose(h); _msFsLastErrno = EINVAL; return MS_EMPTY_STRING; }
		int isDir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
		/* Resize buffer if needed: name + optional "/" + "\n" */
		while (len + nlen + 2 >= cap) {
			size_t newCap = cap * 2;
			char* nb = (char*)msRealloc(buf, cap, newCap);
			if (!nb) { msMemFree(buf); FindClose(h); _msFsLastErrno = ENOMEM; return MS_EMPTY_STRING; }
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
	msMemFree(buf);
	return result;
}

msString msFsReadDirNames(msString path) {
	_msFsLastErrno = 0;
	const char* cpath = msStringToCString(path);
	if (memchr(cpath, '\0', (size_t)msStrLen(path)) != NULL) {
		_msFsLastErrno = EINVAL;
		return MS_EMPTY_STRING;
	}
	wchar_t* pattern = msFsWidePath(path, 2);
	if (!pattern) return MS_EMPTY_STRING;
	DWORD attributes = GetFileAttributesW(pattern);
	if (attributes == INVALID_FILE_ATTRIBUTES ||
		(attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
		_msFsLastErrno = attributes == INVALID_FILE_ATTRIBUTES ?
			msFsErrnoFromWin32(GetLastError()) : ENOTDIR;
		msMemFree(pattern);
		return MS_EMPTY_STRING;
	}
	size_t end = wcslen(pattern);
	if (end > 0 && pattern[end - 1] != L'\\' && pattern[end - 1] != L'/') {
		pattern[end++] = L'\\';
	}
	pattern[end] = L'*';
	pattern[end + 1] = L'\0';
	WIN32_FIND_DATAW data;
	HANDLE directory = FindFirstFileW(pattern, &data);
	DWORD firstError = directory == INVALID_HANDLE_VALUE ? GetLastError() : 0;
	if (directory == INVALID_HANDLE_VALUE && firstError == ERROR_FILE_NOT_FOUND) {
		pattern[end] = L'\0';
		attributes = GetFileAttributesW(pattern);
		if (attributes != INVALID_FILE_ATTRIBUTES &&
			(attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) firstError = 0;
	}
	msMemFree(pattern);
	if (directory == INVALID_HANDLE_VALUE) {
		_msFsLastErrno = firstError == 0 ? 0 : msFsErrnoFromWin32(firstError);
		return MS_EMPTY_STRING;
	}
	size_t capacity = 4096;
	size_t length = 0;
	char* names = (char*)msMemAlloc(capacity);
	int error = names ? 0 : ENOMEM;
	while (error == 0) {
		const wchar_t* name = data.cFileName;
		if (wcscmp(name, L".") != 0 && wcscmp(name, L"..") != 0) {
			int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
				name, -1, NULL, 0, NULL, NULL);
			if (needed <= 0) { error = EINVAL; break; }
			if ((size_t)needed > (size_t)MS_LEN_MAX - length) {
				error = EFBIG;
				break;
			}
			if ((size_t)needed > capacity - length) {
				size_t grown = capacity * 2;
				if (grown < length + needed) grown = length + needed;
				char* next = (char*)msRealloc(names, capacity, grown);
				if (!next) { error = ENOMEM; break; }
				names = next;
				capacity = grown;
			}
			int wrote = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
				name, -1, names + length, needed, NULL, NULL);
			if (wrote != needed) { error = EINVAL; break; }
			length += (size_t)needed;
		}
		if (!FindNextFileW(directory, &data)) {
			DWORD code = GetLastError();
			if (code != ERROR_NO_MORE_FILES) error = msFsErrnoFromWin32(code);
			break;
		}
	}
	if (!FindClose(directory) && error == 0) {
		error = msFsErrnoFromWin32(GetLastError());
	}
	_msFsLastErrno = error;
	msString result = error == 0 && length > 0 ?
		msStringNew(names, (int64_t)length) : MS_EMPTY_STRING;
	msMemFree(names);
	return result;
}
