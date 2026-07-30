// bug070 — closure values crossing the call/param boundary were NEVER
// relation-checked: checkExprPass's arg loop skipped any arg or param of
// Function kind (carve-out for contextually-typed lambdas swallowed ALL
// closures). Nim checks every arg (paramTypesMatch; tyProc params AND return
// invariant via procParamTypeRel, sigmatch.nim:791+). Consequences measured:
// (a) `() => int32` accepted where `() => number` declared — call site casts
// fn to the double-returning ABI, callee returns in eax, caller reads xmm0 →
// denormal garbage (9e-323); (b) a closure accepted where a STRING param is
// declared; (c) `() => number` accepted where `() => string` declared.
// Fix: carve-out narrowed to literal lambdas + generic-containing formals;
// isFunctionAssignable gained the fnSlotReprMismatch gate (numeric repr
// invariance, nullable-union peeled — RaiserContext|null vs RaiserContext is
// pointer-repr-equal and must stay assignable).
// The GENERIC-source variant (mkG<T>(7) → () => int32) is enforced on the CLI
// path but NOT reproducible through compileToCWithStd — the harness leaves
// `() => T` unsubstituted (same family as the bug006 standalone/battery
// divergence row in neon BUGS.md §2).

import { compileToCWithStd } from "../helpers";

test "bug070: () => int32 closure rejected at a () => number param" {
	const src = `
function mkI(v: int32): () => int32 { let val = v; return (): int32 => val; }
function callIt(f: () => number): number { return f(); }
function main(): void { console.log(callIt(mkI(7))); }
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	assert c.error.indexOf("Argument type mismatch", 0) >= 0;
}

test "bug070: closure value rejected at a string param" {
	const src = `
function mkN(v: number): () => number { let val = v; return (): number => val; }
function want(s: string): void { console.log(s); }
function main(): void { want(mkN(7)); }
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
}

test "bug070: () => number closure rejected at a () => string param" {
	const src = `
function mkN(v: number): () => number { let val = v; return (): number => val; }
function wantF(f: () => string): void { console.log(f()); }
function main(): void { wantF(mkN(7)); }
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
}

test "bug070: exact-signature closure stays accepted" {
	const src = `
function mkI(v: int32): () => int32 { let val = v; return (): int32 => val; }
function callIt(f: () => int32): int32 { return f(); }
function main(): void { console.log(callIt(mkI(7))); }
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "bug070: nullable-union return stays assignable (registry callback shape)" {
	const src = `
class Box { n: number; constructor() { this.n = 1; } }
function mk(): Box { return new Box(); }
let cb: () => Box | null = (): Box | null => null;
function register(f: () => Box | null): void { cb = f; }
function main(): void { register(mk); console.log(cb() !== null); }
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "bug070: lambda literals keep contextual typing (no double-report)" {
	const src = `
function each(f: (x: number) => number): number { return f(1); }
function main(): void { console.log(each((x) => x + 1)); }
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}
