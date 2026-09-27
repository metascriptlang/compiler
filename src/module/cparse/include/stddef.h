/* cparse builtin stddef.h */
#ifndef _CPARSE_STDDEF_H
#define _CPARSE_STDDEF_H

#ifdef _WIN64
typedef long long ptrdiff_t;
typedef unsigned long long size_t;
#else
typedef long ptrdiff_t;
typedef unsigned long size_t;
#endif
#ifdef _WIN32
typedef unsigned short wchar_t;
#else
typedef int wchar_t;
#endif

#define NULL ((void *)0)

#endif
