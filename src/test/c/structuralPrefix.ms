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
// The rule is enforced wherever a value of one object type reaches a slot of
// another: call arguments, `return`, initializers, assignment, field stores and
// array-literal elements. Only the object-identity class is gated there —
// numeric narrowing, `Ref`→`Ptr` non-owning links and the nullable idiom keep
// their existing behaviour (a census of the tree put those at 223 sites, all
// deliberate, versus 0 sites of object-shape mismatch).

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

// ===== Assignment positions =====
//
// These reach codegen through the same raw cast as a call argument, so they
// carry the same soundness obligation. They are listed separately because the
// checker consults assignability at each of them through a different path.

const AB_PRELUDE = `
interface B { y: int32; }
interface A { x: int32; y: int32; }
`;

test "structural prefix: initializer rejects a shape mismatch" {
	const c = compileToC(AB_PRELUDE + `
function main(): void {
	const a: A = { x: 11, y: 22 };
	const b: B = a;
	b.y;
}
`);
	assert !c.ok;
}

test "structural prefix: assignment rejects a shape mismatch" {
	const c = compileToC(AB_PRELUDE + `
function main(): void {
	const a: A = { x: 11, y: 22 };
	let b: B = { y: 0 };
	b = a;
	b.y;
}
`);
	assert !c.ok;
}

test "structural prefix: field store rejects a shape mismatch" {
	const c = compileToC(AB_PRELUDE + `
interface P { f: B; }
function main(): void {
	const a: A = { x: 11, y: 22 };
	const p: P = { f: { y: 0 } };
	p.f = a;
}
`);
	assert !c.ok;
}

test "structural prefix: array literal element rejects a shape mismatch" {
	const c = compileToC(AB_PRELUDE + `
function main(): void {
	const a: A = { x: 11, y: 22 };
	const arr: B[] = [a];
	arr[0].y;
}
`);
	assert !c.ok;
}

test "structural prefix: a prefix-compatible initializer still passes" {
	const c = compileToC(`
interface B { x: int32; }
interface A { x: int32; y: int32; }
function main(): void {
	const a: A = { x: 11, y: 22 };
	const b: B = a;
	b.x;
}
`);
	assert c.ok;
}

test "structural prefix: assigning a value to its own type still passes" {
	const c = compileToC(AB_PRELUDE + `
function main(): void {
	const a: A = { x: 11, y: 22 };
	let a2: A = { x: 0, y: 0 };
	a2 = a;
	a2.y;
}
`);
	assert c.ok;
}
