// bug059 — pending generic instances were deduped without module identity
//
// Symptom:    Two modules each declaring a module-private generic with the
//             SAME name, both instantiated with the SAME type argument. Each
//             module compiled alone was green; compiled together the second
//             module's call site failed C compilation:
//                 error: call to undeclared function
//                        'pendingDedup__int32__…bug059Oms_u0'
//             The definition was emitted in no translation unit at all.
//             bug007.ms / bug008.ms are this pair in the wild (`takeWitness<T>`
//             + `enum Color`), which is why fixedbugs/index.ms was red while
//             bug008.ms alone passed.
//
// Root cause: addPendingInstance (src/checker/instantiate.ms) keyed its
//             duplicate check on the bare MS-level mangled name
//             ("pendingDedup__int32"), which carries no module identity, while
//             the drain in compile.ms routes each instance by
//             resolvedSym.modulePath and the C mangler qualifies the emitted
//             name by module. The dedup scope was therefore narrower than the
//             emission scope, so the second module's instance node was dropped
//             silently — no diagnostic, a clean type-check, then a C error.
//             The reference compiler keys its instantiation cache on the
//             generic symbol's itemId, i.e. (module, item), so same-named
//             generics in different modules can never collide.
//
// Fix:        Key the pending-instance dedup on owner ‖ name, with owner taken
//             from resolvedSym.modulePath — the same identity the drain uses to
//             choose the target TU.

import "./bug059helper";

function pendingDedup<T>(x: T | null): int32 {
	return 2;
}

test "bug059: same-named generic in a second module still reaches codegen" {
	const w: int32 | null = null;
	assert pendingDedup(w) === 2;
}

test "bug059: the second module runs its OWN body, not the first module's" {
	const a: int32 | null = null;
	const b: int64 | null = null;
	assert pendingDedup(a) === 2;
	assert pendingDedup(b) === 2;
}
