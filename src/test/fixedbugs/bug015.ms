// bug015 — extended Bug-5a + contextual `new` inference for generics
//
// Combines two fixes that share a UX surface:
//
//   (a) Naming-roundtrip extension. `monoConcreteTypeName` previously
//       emitted single placeholders ("Function", "Union") for compound
//       type kinds substituted into a generic body's annotation strings.
//       The placeholders did NOT roundtrip through `resolveAnnotation` —
//       there is no `Function` / `Union` symbol in scope, so the
//       re-resolved type fell back to Unknown, the generic instance
//       ended up with `void*` fields, and the mangled name disagreed
//       with the caller-side Type-based name. Bug 5a fixed Function
//       only; bug015 extends the same pattern to anonymous Union and
//       Conditional types.
//
//   (b) Contextual type inference for `new`. Pre-fix, the user had to
//       write the type args TWICE for a generic class:
//           const m: Map<K, V> = new Map<K, V>();   // OK
//           const m: Map<K, V> = new Map();         // ✗ "requires
//                                                    explicit type
//                                                    arguments"
//       Now `resolveGenericNewExpr` (src/checker/checkExprPass.ms)
//       reads the contextual `expected` type passed by `checkNewExpr`,
//       peels through Ref/Ptr to the GenericInstance, and pulls the
//       concrete args from `typeChildren`. The "requires explicit
//       type arguments" error still fires when neither source can
//       supply args.

import { compileToC } from "../helpers";

// ===== (b) Contextual `new` inference =====

test "bug015: LHS-only annotation infers type args for new (Map)" {
	const src = `
type Handler = (s: string) => void;
function main(): void {
	const m: Map<string, Handler> = new Map();
	m.set("a", (s) => {});
	const _ok = m.has("a");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug015: RHS-only type args still works (regression guard)" {
	const src = `
type Handler = (s: string) => void;
function main(): void {
	const m = new Map<string, Handler>();
	m.set("a", (s) => {});
	const _ok = m.has("a");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug015: both-sides type args still works (regression guard)" {
	const src = `
type Handler = (s: string) => void;
function main(): void {
	const m: Map<string, Handler> = new Map<string, Handler>();
	m.set("a", (s) => {});
	const _ok = m.has("a");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug015: LHS contextual mismatch still errors" {
	// `const m: Map<K,V> = new Set()` — the contextual type is Map but
	// the new is Set. The "requires explicit type arguments" path
	// SHOULD still fire (or some other type-mismatch error).
	const src = `
function main(): void {
	const m: Map<string, int32> = new Set();
}
`;
	const c = compileToC(src);
	assert !c.ok;
}

// ===== (a) Naming roundtrip — Function in Map slot
// (Bug 5a regression already covers Function specifically; here we
// also exercise the LHS-inferred form to make sure both fixes compose.)

test "bug015: Map<string, Function> with LHS-only annotation" {
	const src = `
type IntFn = (x: int32) => int32;
function main(): void {
	const ops: Map<string, IntFn> = new Map();
	ops.set("dbl", (x) => (x * 2) as int32);
	const _ok = ops.has("dbl");
}
`;
	const c = compileToC(src);
	assert c.ok;
}
