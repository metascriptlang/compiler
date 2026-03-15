// ARO C Header Parser — MetaScript bindings
//
// Wraps the ARO FFI (Zig) via a C bridge layer.
// The bridge converts between MetaScript types (msString) and C types (char*).
//
// Build prerequisites:
//   cd src/bindings/aro && zig build              → zig-out/lib/libaro_ffi.a
//   (bridge.c is auto-compiled by @include("bridge.h") — no manual step needed)

// Emit #include for the bridge header (so C compiler finds prototypes)
@include("bridge.h");

// Compile the bridge C wrapper (converts msString <-> char* for ARO FFI)
@compile("./bridge.c");

// Link the ARO static library
@link("zig-out/lib/libaro_ffi.a");

// ===== Parse =====

// Parse a C header file. Returns 0 on success, 1 on error.
extern function msAroParse(path: string): int32;

// Get error message (empty string if no error).
extern function msAroError(): string;

// Free the current parse result.
extern function msAroFree(): void;

// ===== Functions =====

extern function msAroFuncCount(): int32;
extern function msAroFuncName(i: int32): string;
extern function msAroFuncReturnType(i: int32): string;
extern function msAroFuncParamCount(i: int32): int32;
extern function msAroFuncParamName(fi: int32, pi: int32): string;
extern function msAroFuncParamType(fi: int32, pi: int32): string;
extern function msAroFuncIsVariadic(i: int32): int32;

// ===== Structs =====

extern function msAroStructCount(): int32;
extern function msAroStructName(i: int32): string;
extern function msAroStructIsUnion(i: int32): int32;
extern function msAroStructFieldCount(i: int32): int32;
extern function msAroStructFieldName(si: int32, fi: int32): string;
extern function msAroStructFieldType(si: int32, fi: int32): string;

// ===== Enums =====

extern function msAroEnumCount(): int32;
extern function msAroEnumName(i: int32): string;
extern function msAroEnumMemberCount(i: int32): int32;
extern function msAroEnumMemberName(ei: int32, mi: int32): string;

// ===== Typedefs =====

extern function msAroTypedefCount(): int32;
extern function msAroTypedefName(i: int32): string;
extern function msAroTypedefTarget(i: int32): string;
