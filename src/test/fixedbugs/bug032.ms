// bug032 — generic call with explicit type args silently lost type substitution
//             for closure arg, causing link failure
//
// Symptom:    Compiling
//                 function applyN<T>(n: int32, init: T, f: (acc: T) => T): T { ... }
//                 const r = applyN<int32>(4, 1, (x) => (x * factor) as int32);
//             produced
//                 error: use of undeclared identifier 'dollarlifted_main_1_'
//             at link time. The lifted closure body was simply absent from
//             the emitted C — no compiler error, no warning. Caller code
//             referenced it via a (msClosure){.fn = (void*)dollarlifted_main_1_, ...}
//             literal, but no `static int32_t dollarlifted_main_1_(...)` body
//             existed in any TU.
//
// Root cause: src/checker/checkExprPass.ms (checkCallExpr around line 2218).
//             The pre-arg-walk `paramHints` derivation ONLY considered
//             backward inference from `expectedType` (the caller's return-type
//             hint). It did NOT apply explicit type args (`<int32>`).
//             As a result, when checking the closure argument, the formal
//             expected type was still `(T) => T` with `T` as GenericParam.
//             checkAnonymousFunction inherits param types from
//             `expectedType.typeChildren`, so the closure's untyped `x` param
//             was typed as GenericParam('T'). Lambda lifting preserved this
//             through preserveResolvedTypes. The lifted fn's nodeType
//             carried a GenericParam in typeChildren[0]. C codegen's
//             `genFunctionDecl` bailed at `hasGenericParams(fnType)` (line ~150
//             in src/codegen/c/declarations.ms) — silently — and the body was
//             never emitted.
//
// Fix:        checkCallExpr now applies BOTH explicit type args AND backward
//             inference into a unified `bindings` accumulator BEFORE the arg
//             check loop. The substituted formal types drive paramHints, so
//             closure args see concrete formal types (e.g. `(int32) => int32`)
//             and their untyped params inherit concrete types — no
//             GenericParam leakage downstream.
//
// 3-pass spirit: this is bidirectional checking with eager concrete
//                substitution at the call-expression boundary. No re-check,
//                no inference vars, no backtracking — pattern compatible with
//                MS's "set once in Pass 3, stable for downstream" invariant.

function bug032_applyN<T>(n: int32, init: T, f: (acc: T) => T): T {
	let acc: T = init;
	let i: int32 = 0 as int32;
	while (i < n) {
		acc = f(acc);
		i = (i + (1 as int32)) as int32;
	}
	return acc;
}

test "bug032: generic call with explicit type args + capturing closure compiles and runs" {
	const factor: int32 = 3 as int32;
	const r = bug032_applyN<int32>(4 as int32, 1 as int32, (x) => (x * factor) as int32);
	assert r === 81;
}

test "bug032: generic call with non-capturing closure also works" {
	const r = bug032_applyN<int32>(3 as int32, 2 as int32, (x) => (x + (10 as int32)) as int32);
	assert r === 32;
}
