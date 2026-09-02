// bug118 — zero-arg arrow literal into an (e: T) => void slot: accepted at
//          param position but MISCOMPILED on C, rejected at field position
//
// Symptom:    `fire(() => {...})` with fire(handler: (e: Ev) => void) type-checked
//             clean, but C called the 0-param closure through the SLOT's declared
//             signature (extra by-value struct arg) → garbage frame → double-free
//             in the struct's destructor (found via Neon's NeonEvent fireEvent).
//             The SAME assignment in a struct field errored:
//             "Type 'function' is not assignable to type 'function' for field".
// Root cause: literal lambdas are exempt from the arg relation-check
//             (callResolve ec38c20 family) because they are typed CONTEXTUALLY —
//             but checkAnonymousFunction only types the params the user WROTE.
//             A 0-arg arrow kept type `() => void`, no conversion was ever
//             materialized, and codegen casts fn to the DECLARED slot signature
//             (compat.ms fnSlotReprMismatch comment), so the call ABI lied.
//             isFunctionAssignable meanwhile requires exact arity → field reject.
// Fix:        padLiteralParams (checkExprPass.ms): at the literal's own
//             contextual-typing site, pad the written param list with synthetic
//             `__msPadN` params typed from the concrete fn-typed formal, so
//             scope, lifter and codegen all see the slot's full signature.
//             TS semantics (fewer params OK); DIVERGE-INTENTIONAL vs Nim
//             procTypeRel (sigmatch.nim:813 exact signatureLen). Fn VALUES
//             (non-literals) keep the strict relation — loud error.
//             Runtime pin (no double-free): neon tests/render/event.test.ms.

import { compileToC, compileToJS } from "../helpers";

const b118field = `
interface Ev { kind: string; value: string; }
interface Slot { name: string; handler: (e: Ev) => void; }
function b118(): void {
	let runs = 0;
	const s: Slot = { name: "k", handler: () => { runs = runs + 1; } };
	s.handler({ kind: "k", value: "v" });
	const slots: Slot[] = [{ name: "a", handler: (): void => { runs = runs + 1; } }];
	slots[0].handler({ kind: "a", value: "v" });
	console.log(runs);
}
b118();
`;

const b118param = `
interface Ev { kind: string; value: string; }
function fire(handler: (e: Ev) => void): void {
	handler({ kind: "f", value: "v" });
}
function fire2(handler: (a: string, b: number) => void): void {
	handler("s", 42);
}
function b118(): void {
	fire(() => { console.log("z"); });
	fire(e => { console.log(e.value); });
	fire2(a => { console.log(a); });
}
b118();
`;

test "bug118: zero-arg arrow accepted in fn-typed field and slot array" {
	const out = compileToC(b118field);
	assert out.ok;
}

test "bug118: padded params reach the C signature (ABI carries the slot arity)" {
	const out = compileToC(b118param);
	assert out.ok;
	if (out.ok) {
		assert out.value.contains("__msPad");
	}
}

test "bug118: js lane accepts and pads literals the same way" {
	const out = compileToJS(b118param);
	assert out.ok;
	if (out.ok) {
		assert out.value.contains("__msPad");
	}
}
