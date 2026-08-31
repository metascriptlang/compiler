// nim-guard: an owner's =destroy must destroy its refcounted FIELDS.
//
// The reference lifts hooks by routing on the field's type kind, one arm per
// family (`of tyRef:` → the ref op). Our port is fillBody in
// src/transform/lowering/destructorLifting.ms. A refcounted kind MISSING from
// that table does not fail loudly — it falls through to defaultOp, so the owner
// is freed and the field's heap value never is. Nothing else catches this: the
// program prints correct values, exits 0, and ASan sees a live allocation, not
// a fault.
//
// Proven red before the BigInt arm existed: 100 owners → bigint alloc=100
// destroy=0. Every shape below leaked; the plain `bigint[]` case did not, which
// is why an element-only probe would have passed while every field leaked.
//
// GUARD-BALANCE bigint
// GUARD-JS

interface Box { v: bigint; }
struct SBox { v: bigint; }
interface Outer { inner: Box; tag: bigint; }

function mkBox(i: int32): Box { return { v: i as bigint }; }
function mkS(i: int32): SBox { return { v: i as bigint }; }

function main(): void {
	for (let i = 0; i < 50; i += 1) { const b: Box = mkBox(i); }
	for (let i = 0; i < 50; i += 1) { const s: SBox = mkS(i); }
	for (let i = 0; i < 50; i += 1) { const o: Outer = { inner: mkBox(i), tag: 7n }; }

	const arr: Box[] = new Array(16);
	for (let i = 0; i < 16; i += 1) { arr[i] = mkBox(i); }
	// Reassignment takes the sink path: the overwritten field value is the one a
	// missing arm drops on the floor.
	for (let i = 0; i < 64; i += 1) { arr[i % 16] = mkBox(i); }

	const box: Box = { v: 0n };
	for (let i = 0; i < 64; i += 1) { box.v = i as bigint; }

	console.log(box.v.toString());
	console.log(arr[3].v.toString());
	console.log("GUARD-OK");
}
main();
