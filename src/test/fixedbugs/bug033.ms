// bug033 — array of closures crashed at scope-exit cleanup
//
// Symptom:    A function returning `(() => T)[]` (closures stored in an
//             array) prints correct values but PANICS on cleanup:
//                 thread N panic: member access within misaligned address
//                 for type 'msRefHeader', which requires 8 byte alignment
//                 msDecRefIsLast (runtime/drc.h:201)
//                 msRefArrayDestroy (runtime/core/array.c:558)
//             Minimal repro (works pre-fix until last line, then crashes):
//                 function makeFns(): (() => int32)[] {
//                     const fns: (() => int32)[] = [];
//                     ...
//                     fns.push(() => x);
//                     return fns;
//                 }
//                 const fns = makeFns();
//                 for (const f of fns) console.log(f().toString());
//                 // ← scope exit triggers msArrayRefDestroy(fns) → CRASH
//
// Root cause: src/analyzer/classify.ms classifyArray() had 7 explicit
//             cases (Uint8/primitive/String/Array/Struct/Ref/Ptr) plus an
//             unsafe default fallthrough that returned msArrayRefDestroy
//             family. Closure-element arrays fell into the default.
//
//             But msArrayRefDestroy assumes `data[]` is `void*[]`
//             (8B stride). Closure arrays generate per-module
//             `msClosureArray__Content { cap; msClosure data[]; }` which
//             stores msClosure structs INLINE (16B stride: fn + env).
//             The macro `msArrayRefDestroy` casts `msClosureArray*` to
//             `msRefArray*` and reads `data[i]` as `void*` — reading the
//             function pointer as if it were a heap-ref → msHeader(elem)
//             walks into .text section → misaligned access → crash.
//
//             Also affected (same family, different TypeKind, separate
//             fixedbugs entries): Union[] (bug034 — silent leak of inner
//             refs, crashes with realistic payload), Distinct[] (bug035
//             — buffer overflow under stress, SIGSEGV).
//
// Fix:        Three coordinated layers:
//             1. runtime/core/system.h + array.c — added msClosureArray
//                struct + msClosureArrayDestroy/Copy/Push/WasMoved
//                helpers. Single typed helper works for ALL closure types
//                (closure layout is uniform: per-env cleanup is virtual-
//                dispatched via env's typeInfo, not per-closure variation).
//             2. src/codegen/c/types.ms — getArrayTypeName /
//                getArrayContentType / genArrayType now route
//                `msClosure` element to runtime `msClosureArray` (skip
//                per-module typedef that would duplicate runtime decl).
//             3. src/analyzer/classify.ms — added explicit Function case
//                BEFORE the default fallthrough, returning the new
//                `msArrayClosure*` hook names.
//
// Architectural note: this follows MS's existing hybrid pattern (runtime
//             helper for uniform-layout element types, per-T lift for
//             variant-layout element types). Closure is uniform layout
//             → runtime helper, consistent with msStringArray + msRefArray
//             precedents. NOT a full Nim-parity per-T lift (which would
//             generate identical bodies N times for N closure types).

function bug033_makeFns(): (() => int32)[] {
	const fns: (() => int32)[] = [];
	let i: int32 = 0 as int32;
	while (i < (3 as int32)) {
		const x = i;
		fns.push(() => x);
		i = (i + (1 as int32)) as int32;
	}
	return fns;
}

test "bug033: closure array prints correct per-iteration captures" {
	const fns = bug033_makeFns();
	assert fns.length == 3;
	assert fns[0]() == 0;
	assert fns[1]() == 1;
	assert fns[2]() == 2;
}

test "bug033: scope-exit cleanup on closure array runs without crash" {
	// The crash was deterministic at scope exit — if this test FUNCTION
	// completes without segfault, the cleanup succeeded.
	let iter: int32 = 0 as int32;
	while (iter < (50 as int32)) {
		const fns = bug033_makeFns();
		iter = (iter + (1 as int32)) as int32;
		// `fns` falls out of scope each iteration — triggers
		// msArrayClosureDestroy(fns_). Pre-fix: msArrayRefDestroy → crash.
	}
	assert iter == 50;
}
