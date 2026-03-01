// ARO bridge — MetaScript-compatible wrapper around ARO FFI
//
// Converts between MetaScript runtime types (msString) and ARO C types (char*).
// The self-hosted compiler calls these functions to parse C headers.
//
// Usage from MetaScript:
//   @include("bridge.h")
//   @link("path/to/bridge.o")
//   @link("path/to/libaro_ffi.a")
//   extern function ms_aro_parse(path: string): int32;
//   extern function ms_aro_func_count(): int32;
//   ...

#ifndef ARO_BRIDGE_H
#define ARO_BRIDGE_H

#include <stdint.h>
#include "ms_string.h"

// Parse a C header file. Returns 0 on success, 1 on error.
// Stores results internally (global state, single-threaded).
int32_t ms_aro_parse(msString path);

// Get error message (empty string if no error).
msString ms_aro_error(void);

// Free the current parse result.
void ms_aro_free(void);

// --- Functions ---
int32_t ms_aro_func_count(void);
msString ms_aro_func_name(int32_t i);
msString ms_aro_func_return_type(int32_t i);
int32_t ms_aro_func_param_count(int32_t i);
msString ms_aro_func_param_name(int32_t fi, int32_t pi);
msString ms_aro_func_param_type(int32_t fi, int32_t pi);
int32_t ms_aro_func_is_variadic(int32_t i);

// --- Structs ---
int32_t ms_aro_struct_count(void);
msString ms_aro_struct_name(int32_t i);
int32_t ms_aro_struct_is_union(int32_t i);
int32_t ms_aro_struct_field_count(int32_t i);
msString ms_aro_struct_field_name(int32_t si, int32_t fi);
msString ms_aro_struct_field_type(int32_t si, int32_t fi);

// --- Enums ---
int32_t ms_aro_enum_count(void);
msString ms_aro_enum_name(int32_t i);
int32_t ms_aro_enum_member_count(int32_t i);
msString ms_aro_enum_member_name(int32_t ei, int32_t mi);

// --- Typedefs ---
int32_t ms_aro_typedef_count(void);
msString ms_aro_typedef_name(int32_t i);
msString ms_aro_typedef_target(int32_t i);

#endif
