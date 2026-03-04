// ARO bridge — MetaScript-compatible wrapper around ARO FFI
//
// Converts between MetaScript runtime types (msString) and ARO C types (char*).
// The self-hosted compiler calls these functions to parse C headers.
//
// Usage from MetaScript:
//   @include("bridge.h")
//   @link("path/to/bridge.o")
//   @link("path/to/libaro_ffi.a")
//   extern function msAroParse(path: string): int32;
//   extern function msAroFuncCount(): int32;
//   ...

#ifndef ARO_BRIDGE_H
#define ARO_BRIDGE_H

#include <stdint.h>
#include "ms_string.h"

// Parse a C header file. Returns 0 on success, 1 on error.
// Stores results internally (global state, single-threaded).
int32_t msAroParse(msString path);

// Get error message (empty string if no error).
msString msAroError(void);

// Free the current parse result.
void msAroFree(void);

// --- Functions ---
int32_t msAroFuncCount(void);
msString msAroFuncName(int32_t i);
msString msAroFuncReturnType(int32_t i);
int32_t msAroFuncParamCount(int32_t i);
msString msAroFuncParamName(int32_t fi, int32_t pi);
msString msAroFuncParamType(int32_t fi, int32_t pi);
int32_t msAroFuncIsVariadic(int32_t i);

// --- Structs ---
int32_t msAroStructCount(void);
msString msAroStructName(int32_t i);
int32_t msAroStructIsUnion(int32_t i);
int32_t msAroStructFieldCount(int32_t i);
msString msAroStructFieldName(int32_t si, int32_t fi);
msString msAroStructFieldType(int32_t si, int32_t fi);

// --- Enums ---
int32_t msAroEnumCount(void);
msString msAroEnumName(int32_t i);
int32_t msAroEnumMemberCount(int32_t i);
msString msAroEnumMemberName(int32_t ei, int32_t mi);

// --- Typedefs ---
int32_t msAroTypedefCount(void);
msString msAroTypedefName(int32_t i);
msString msAroTypedefTarget(int32_t i);

#endif
