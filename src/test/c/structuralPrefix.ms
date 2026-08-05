// Structural (width) subtyping is implemented as a RAW POINTER CAST at the C
// level, so it is only sound when the target's fields sit at the same offsets
// in the source — i.e. the target is a positional PREFIX of the source, field
// for field, same repr. The reference permits object upcasts for exactly this
// reason (the declared parent embeds as the layout prefix); it has no
// structural path for records at all.
//
// Without the prefix gate, `b.y` on an `A{x,y}` passed as `B{y}` reads offset 0
// and returns A's x (silent wrong value), and when the fields differ in repr it
// reinterprets an integer as a pointer.
//
// SCOPE: call arguments and `return` are the only positions that consult
// assignability at all. `const b: B = a`, `b = a`, `p.f = a` and `[a]` against
// `B[]` reach codegen unchecked, so the same raw cast still happens there —
// a separate hole (the checker never enforces initializer/assignment types),
// tracked in docs/TSGAP.md. Tests for those belong with that fix, not here.

import { compileToC } from "../helpers";

test "structural prefix: target fields are a positional prefix" {
	const c = compileToC(`
interface B { x: int32; }
interface A { x: int32; y: int32; }
function takeB(b: B): int32 { return b.x; }
function main(): void {
	const a: A = { x: 11, y: 22 };
	takeB(a);
}
`);
	assert c.ok;
}

test "structural prefix: declared extends stays assignable" {
	const c = compileToC(`
interface B { x: int32; }
interface A extends B { y: int32; }
function takeB(b: B): int32 { return b.x; }
function main(): void {
	const a: A = { x: 41, y: 42 };
	takeB(a);
}
`);
	assert c.ok;
}

test "structural prefix: shared field at a different offset is rejected" {
	const c = compileToC(`
interface B { y: int32; }
interface A { x: int32; y: int32; }
function takeB(b: B): int32 { return b.y; }
function main(): void {
	const a: A = { x: 11, y: 22 };
	takeB(a);
}
`);
	assert !c.ok;
}

test "structural prefix: offset shift across reprs is rejected" {
	const c = compileToC(`
interface B { s: string; }
interface A { n: int32; s: string; }
function takeB(b: B): string { return b.s; }
function main(): void {
	const a: A = { n: 12345, s: "hello" };
	takeB(a);
}
`);
	assert !c.ok;
}

test "structural prefix: reordered fields are rejected" {
	const c = compileToC(`
interface B { x: int32; y: int32; }
interface A { y: int32; x: int32; }
function takeB(b: B): int32 { return b.x; }
function main(): void {
	const a: A = { y: 22, x: 11 };
	takeB(a);
}
`);
	assert !c.ok;
}

// "got A, expected B" alone reads like a compiler bug when A visibly has B's
// field — the diagnostic has to name the slot that moved.
test "structural prefix: the diagnostic names the moved field" {
	const c = compileToC(`
interface B { y: int32; }
interface A { x: int32; y: int32; }
function takeB(b: B): int32 { return b.y; }
function main(): void {
	const a: A = { x: 11, y: 22 };
	takeB(a);
}
`);
	assert !c.ok;
	assert c.error.contains("'y' is field 0 of B but field 1 of A");
	assert c.error.contains("extends B");
}

test "structural prefix: return position obeys the same rule" {
	const c = compileToC(`
interface B { y: int32; }
interface A { x: int32; y: int32; }
function mk(): B {
	const a: A = { x: 11, y: 22 };
	return a;
}
function main(): void { mk(); }
`);
	assert !c.ok;
}
