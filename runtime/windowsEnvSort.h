#ifndef MS_WINDOWS_ENV_SORT_H
#define MS_WINDOWS_ENV_SORT_H

#include <stdlib.h>
#include <wchar.h>
#include <windows.h>

/* Kept in C: the order of entries whose keys compare equal (two keys that encode to one) is the CRT
 * qsort's, as libuv's, and a .cms extern cannot pass the C comparator qsort takes. */
static inline int msWindowsEnvKeyCompare(const void* a, const void* b) {
	const wchar_t* left = *(const wchar_t* const*)a;
	const wchar_t* right = *(const wchar_t* const*)b;
	const wchar_t* le = wcschr(left, L'=');
	const wchar_t* re = wcschr(right, L'=');
	int ln = le ? (int)(le - left) : (int)wcslen(left);
	int rn = re ? (int)(re - right) : (int)wcslen(right);
	return CompareStringOrdinal(left, ln, right, rn, TRUE) - CSTR_EQUAL;
}

static inline void msWindowsEnvSort(wchar_t** items, size_t count) {
	qsort(items, count, sizeof(wchar_t*), msWindowsEnvKeyCompare);
}

#endif
