// ARO C Header Parser — MetaScript bindings
//
// Wraps the ARO FFI (Zig) via a C bridge layer.
// The bridge converts between MetaScript types (msString) and C types (char*).
//
// Build prerequisites:
//   cd src/bindings/aro && zig build              → zig-out/lib/libaro_ffi.a
//   (bridge.c is auto-compiled by @include("bridge.h") — no manual step needed)

// Emit #include for the bridge header (so C compiler finds prototypes)
@include("bridge.h")

// Link the ARO static library (bridge.c is auto-compiled via @include("bridge.h"))
// NOTE: @link paths resolve relative to the declaring module's directory
@link("zig-out/lib/libaro_ffi.a")

// ===== Parse =====

// Parse a C header file. Returns 0 on success, 1 on error.
extern function ms_aro_parse(path: string): int32;

// Get error message (empty string if no error).
extern function ms_aro_error(): string;

// Free the current parse result.
extern function ms_aro_free(): void;

// ===== Functions =====

extern function ms_aro_func_count(): int32;
extern function ms_aro_func_name(i: int32): string;
extern function ms_aro_func_return_type(i: int32): string;
extern function ms_aro_func_param_count(i: int32): int32;
extern function ms_aro_func_param_name(fi: int32, pi: int32): string;
extern function ms_aro_func_param_type(fi: int32, pi: int32): string;
extern function ms_aro_func_is_variadic(i: int32): int32;

// ===== Structs =====

extern function ms_aro_struct_count(): int32;
extern function ms_aro_struct_name(i: int32): string;
extern function ms_aro_struct_is_union(i: int32): int32;
extern function ms_aro_struct_field_count(i: int32): int32;
extern function ms_aro_struct_field_name(si: int32, fi: int32): string;
extern function ms_aro_struct_field_type(si: int32, fi: int32): string;

// ===== Enums =====

extern function ms_aro_enum_count(): int32;
extern function ms_aro_enum_name(i: int32): string;
extern function ms_aro_enum_member_count(i: int32): int32;
extern function ms_aro_enum_member_name(ei: int32, mi: int32): string;

// ===== Typedefs =====

extern function ms_aro_typedef_count(): int32;
extern function ms_aro_typedef_name(i: int32): string;
extern function ms_aro_typedef_target(i: int32): string;
