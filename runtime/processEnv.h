#ifndef MS_PROCESS_ENV_H
#define MS_PROCESS_ENV_H

#include <limits.h>

#if defined(_WIN32)
#include <wchar.h>

static inline wchar_t* _msProcChildWide(const char*, int);

static inline size_t _msEnvKeyLength(const wchar_t* pair) {
	const wchar_t* eq = wcschr(pair, L'=');
	return eq ? (size_t)(eq - pair) : wcslen(pair);
}

static inline int _msEnvKeyCompare(const void* a, const void* b) {
	const wchar_t* left = *(const wchar_t* const*)a;
	const wchar_t* right = *(const wchar_t* const*)b;
	return CompareStringOrdinal(left, (int)_msEnvKeyLength(left),
		right, (int)_msEnvKeyLength(right), TRUE) - CSTR_EQUAL;
}

static inline void _msEnvFreeWide(wchar_t** items, size_t count) {
	for (size_t i = 0; i < count; i++) free(items[i]);
	free(items);
}

static inline wchar_t* _msEnvBlock(msStringArray* pairs, int* error) {
	static const wchar_t* const required[] = {
		L"HOMEDRIVE", L"HOMEPATH", L"LOGONSERVER", L"PATH", L"SYSTEMDRIVE",
		L"SYSTEMROOT", L"TEMP", L"USERDOMAIN", L"USERNAME", L"USERPROFILE",
		L"WINDIR"
	};
	size_t n = pairs && pairs->p ? (size_t)pairs->len : 0;
	if (n > SIZE_MAX / sizeof(wchar_t*) - 11) {
		*error = ENOMEM;
		return NULL;
	}
	wchar_t** items = (wchar_t**)calloc(n + 11, sizeof(wchar_t*));
	if (!items) { *error = ENOMEM; return NULL; }
	size_t count = 0;
	for (size_t i = 0; i < n; i++) {
		msString pair = pairs->p->data[i];
		if (memchr(msStrData(&pair), 0,
			(size_t)msStrLen(pair))) { *error = EINVAL; goto failed; }
		items[count] = _msProcChildWide(msStringToCString(pair), 0);
		if (!items[count]) { *error = ENOMEM; goto failed; }
		count++;
	}
	qsort(items, n, sizeof(wchar_t*), _msEnvKeyCompare);
	for (size_t i = 0; i < 11; i++) {
		int present = 0;
		for (size_t j = 0; j < n; j++) {
			if (CompareStringOrdinal(items[j], (int)_msEnvKeyLength(items[j]),
				required[i], -1, TRUE) == CSTR_EQUAL) { present = 1; break; }
		}
		if (present) continue;
		DWORD size = GetEnvironmentVariableW(required[i], NULL, 0);
		if (!size) continue;
		size_t key = wcslen(required[i]);
		if ((uint64_t)size + key + 1 > SIZE_MAX / sizeof(wchar_t)) {
			*error = ENOMEM; goto failed;
		}
		wchar_t* item = (wchar_t*)malloc((size + key + 1) * sizeof(wchar_t));
		if (!item) { *error = ENOMEM; goto failed; }
		memcpy(item, required[i], key * sizeof(wchar_t));
		item[key] = L'=';
		DWORD got = GetEnvironmentVariableW(required[i], item + key + 1, size);
		if (!got) { free(item); continue; }
		if (got >= size) { free(item); *error = EAGAIN; goto failed; }
		items[count++] = item;
	}
	size_t units = 1;
	for (size_t i = 0; i < count; i++) {
		size_t size = wcslen(items[i]) + 1;
		if (size > SIZE_MAX / sizeof(wchar_t) - units) {
			*error = ENOMEM; goto failed;
		}
		units += size;
	}
	if (units < 2) units = 2;
	wchar_t* block = (wchar_t*)calloc(units, sizeof(wchar_t));
	if (!block) { *error = ENOMEM; goto failed; }
	wchar_t* at = block;
	size_t supplied = 0, inherited = n;
	while (supplied < n || inherited < count) {
		size_t next;
		if (inherited == count || (supplied < n &&
			_msEnvKeyCompare(&items[supplied], &items[inherited]) < 0)) {
			next = supplied++;
		} else { next = inherited++; }
		size_t size = wcslen(items[next]) + 1;
		memcpy(at, items[next], size * sizeof(wchar_t));
		at += size;
	}
	_msEnvFreeWide(items, count);
	return block;
failed:
	_msEnvFreeWide(items, count);
	return NULL;
}

static inline const wchar_t* _msEnvPath(const wchar_t* block) {
	for (const wchar_t* p = block; *p; p += wcslen(p) + 1) {
		if (_msEnvKeyLength(p) == 4 &&
			CompareStringOrdinal(p, 4, L"PATH", 4, TRUE) == CSTR_EQUAL) {
			return p + 5;
		}
	}
	return NULL;
}

static inline int _msEnvSeparator(wchar_t c) {
	return c == L'\\' || c == L'/' || c == L':';
}

static inline wchar_t* _msEnvJoinTest(
	const wchar_t* dir, size_t dn, const wchar_t* name, size_t nn,
	const wchar_t* ext, size_t en, const wchar_t* cwd, size_t cn, int* error
) {
	if (dn > 2 && (dir[0] == L'/' || dir[0] == L'\\') &&
		(dir[1] == L'/' || dir[1] == L'\\')) {
		cn = 0;
	} else if (dn && (dir[0] == L'/' || dir[0] == L'\\')) {
		cn = cn < 2 ? cn : 2;
	} else if (dn >= 2 && dir[1] == L':' &&
		(dn < 3 || (dir[2] != L'/' && dir[2] != L'\\'))) {
		if (cn < 2 || CompareStringOrdinal(cwd, 2, dir, 2, TRUE) != CSTR_EQUAL) {
			cn = 0;
		} else { dir += 2; dn -= 2; }
	} else if (dn > 2 && dir[1] == L':') { cn = 0; }
	uint64_t units = (uint64_t)cn + dn + nn + en + 4;
	if (units > SIZE_MAX / sizeof(wchar_t)) {
		*error = ENOMEM; return NULL;
	}
	wchar_t* result = (wchar_t*)malloc((size_t)units * sizeof(wchar_t));
	if (!result) { *error = ENOMEM; return NULL; }
	wchar_t* at = result;
	memcpy(at, cwd, cn * sizeof(wchar_t)); at += cn;
	if (cn && !_msEnvSeparator(at[-1])) *at++ = L'\\';
	memcpy(at, dir, dn * sizeof(wchar_t)); at += dn;
	if (dn && !_msEnvSeparator(at[-1])) *at++ = L'\\';
	memcpy(at, name, nn * sizeof(wchar_t)); at += nn;
	if (en) {
		if (nn && at[-1] != L'.') *at++ = L'.';
		memcpy(at, ext, en * sizeof(wchar_t)); at += en;
	}
	*at = L'\0';
	DWORD attrs = GetFileAttributesW(result);
	if (attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
		return result;
	}
	free(result);
	return NULL;
}

static inline wchar_t* _msEnvTryExtensions(
	const wchar_t* dir, size_t dn, const wchar_t* name, size_t nn,
	const wchar_t* cwd, size_t cn, int exact, int* error
) {
	wchar_t* found = NULL;
	if (exact) found = _msEnvJoinTest(dir, dn, name, nn, L"", 0, cwd, cn, error);
	if (!found && !*error) {
		found = _msEnvJoinTest(dir, dn, name, nn, L"com", 3, cwd, cn, error);
	}
	if (!found && !*error) {
		found = _msEnvJoinTest(dir, dn, name, nn, L"exe", 3, cwd, cn, error);
	}
	return found;
}

static inline wchar_t* _msEnvSearchPath(
	const wchar_t* file, const wchar_t* cwd, const wchar_t* path, int* error
) {
	size_t fn = wcslen(file), cn = wcslen(cwd);
	if (!fn || (fn == 1 && file[0] == L'.')) return NULL;
	const wchar_t* name = file + fn;
	while (name > file && !_msEnvSeparator(name[-1])) name--;
	const wchar_t* dot = wcschr(name, L'.');
	int exact = dot && dot[1];
	if (name != file) {
		return _msEnvTryExtensions(file, (size_t)(name - file), name,
			fn - (size_t)(name - file), cwd, cn, exact, error);
	}
	wchar_t* found = NULL;
	if (NeedCurrentDirectoryForExePathW(L"")) {
		found = _msEnvTryExtensions(L"", 0, file, fn, cwd, cn, exact, error);
	}
	const wchar_t* p = path;
	while (!found && !*error && p && *p) {
		if (*p == L';') { p++; continue; }
		const wchar_t* end = p;
		if (*p == L'"' || *p == L'\'') {
			end = wcschr(p + 1, *p);
			if (!end) end = p + wcslen(p);
		}
		const wchar_t* semi = wcschr(end, L';');
		end = semi ? semi : p + wcslen(p);
		const wchar_t* dir = p;
		size_t size = (size_t)(end - p);
		if (size && (*dir == L'"' || *dir == L'\'')) { dir++; size--; }
		if (size && (dir[size - 1] == L'"' || dir[size - 1] == L'\'')) size--;
		if (size) {
			found = _msEnvTryExtensions(dir, size, file, fn, cwd, cn, exact, error);
		}
		p = *end ? end + 1 : end;
	}
	return found;
}

static inline wchar_t* _msEnvExecutable(
	msString file, const wchar_t* childCwd, const wchar_t* block, int* error
) {
	wchar_t* name = _msProcChildWide(msStringToCString(file), 1);
	wchar_t* cwd = NULL;
	if (!name) { *error = ENOMEM; return NULL; }
	if (!childCwd) {
		DWORD size = GetCurrentDirectoryW(0, NULL);
		if (size) cwd = (wchar_t*)malloc((size_t)size * sizeof(wchar_t));
		if (!cwd) { free(name); *error = ENOMEM; return NULL; }
		DWORD got = GetCurrentDirectoryW(size, cwd);
		if (!got || got >= size) {
			free(name); free(cwd); *error = EINVAL; return NULL;
		}
		childCwd = cwd;
	}
	DWORD attrs = GetFileAttributesW(childCwd);
	wchar_t* found = NULL;
	if (attrs == INVALID_FILE_ATTRIBUTES) {
		*error = GetLastError() == ERROR_ACCESS_DENIED ? EACCES : ENOENT;
	} else if (!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
		*error = ENOENT;
	} else {
		found = _msEnvSearchPath(name, childCwd, _msEnvPath(block), error);
		if (!found && !*error) *error = ENOENT;
	}
	free(name); free(cwd);
	return found;
}

#elif !MS_NO_SPAWN
#include <paths.h>

static inline void _msEnvFreePairs(char** envp) {
	if (!envp) return;
	for (char** p = envp; *p; p++) free(*p);
	free(envp);
}

static inline char** _msEnvPairs(msStringArray* pairs, int* error) {
	size_t count = pairs && pairs->p ? (size_t)pairs->len : 0;
	if (count > SIZE_MAX / sizeof(char*) - 1) {
		*error = ENOMEM; return NULL;
	}
	char** envp = (char**)calloc(count + 1, sizeof(char*));
	if (!envp) { *error = ENOMEM; return NULL; }
	for (size_t i = 0; i < count; i++) {
		msString pair = pairs->p->data[i];
		size_t n = (size_t)msStrLen(pair);
		if (n == SIZE_MAX || memchr(msStrData(&pair), 0, n)) {
			*error = EINVAL; _msEnvFreePairs(envp); return NULL;
		}
		envp[i] = (char*)malloc(n + 1);
		if (!envp[i]) { *error = ENOMEM; _msEnvFreePairs(envp); return NULL; }
		memcpy(envp[i], msStrData(&pair), n);
		envp[i][n] = '\0';
	}
	return envp;
}

static inline int _msEnvSpawnLocked(
	pid_t* pid, const char* file, const posix_spawn_file_actions_t* actions,
	const posix_spawnattr_t* attrs, char* const argv[], char* const envp[]
) {
	if (!*file) return ENOENT;
	if (strchr(file, '/')) {
		int result;
		do { result = posix_spawn(pid, file, actions, attrs, argv, envp); }
		while (result == EINTR);
		return result;
	}
	const char* path = NULL;
	for (char* const* p = envp; *p; p++) {
		if (strncmp(*p, "PATH=", 5) == 0) { path = *p + 5; break; }
	}
	if (!path) path = _PATH_DEFPATH;
	size_t pn = strnlen(path, PATH_MAX - 1) + 1;
	size_t fn = strlen(file);
	if (fn > NAME_MAX) return ENAMETOOLONG;
	char candidate[PATH_MAX + NAME_MAX + 1];
	int denied = 0;
	const char* p = path;
	for (;;) {
		const char* end = strchr(p, ':');
		if (!end) end = p + strlen(p);
		size_t n = (size_t)(end - p);
		if (n < pn) {
			memcpy(candidate, p, n);
			candidate[n] = '/';
			memcpy(candidate + n + (n != 0), file, fn + 1);
			int result;
			do { result = posix_spawn(pid, candidate, actions, attrs, argv, envp); }
			while (result == EINTR);
			if (result == EACCES) denied = 1;
			else if (result != ENOENT && result != ENOTDIR) return result;
		}
		if (!*end) break;
		p = end + 1;
	}
	return denied ? EACCES : ENOENT;
}
#endif
#endif
