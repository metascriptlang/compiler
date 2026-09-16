// bug172 — a function body could not be given a fixed C symbol
//
// Symptom:    a C host (ctypes over an --app=lib build, a C shim) could not call a MetaScript function.
//             Every routine is emitted as `name__<module>_u<n>`; `export extern function f() { ... }` is an
//             import, so its body is dropped; the legacy `@runtime("c_name")` only renamed call sites and
//             was removed in 047604d8.
// Root cause: no directive pinned a C name on a definition with external linkage,
//             generated whether or not anything calls it.
// Fix:        `@exportName("c_name")` / bare `@exportName` sets Symbol.exportName in collectPass;
//             mangledFunctionName returns it, genFunctionDecl drops `static`, reachability roots it.

@exportName("bug172_answer")
function answer172(): int32 {
	return 42;
}

@exportName
export function bug172_bare(): int32 {
	return 7;
}

extern function bug172_answer(): int32;

test "bug172: @exportName pins the C symbol of a function body" {
	assert bug172_answer() == 42;
	assert bug172_bare() == 7;
}
