// A `{…}` object type is a reference, like an interface; only `struct` copies.
// Aliases, writes through a parameter, array elements, struct fields, generic
// aliases, union members and unannotated literals all share one cell. Nim: TS
// objects map to `ref object` (semstmts.nim typeSectionFinalPass `:ObjectType`),
// `struct` to `object`. NIM-REF CG-38. RED MEANS a `{…}` value was copied —
// run /trace-nim on the alias.
// GUARD-JS

type T = { a: int32; s: string };
type Box<V> = { value: V };
type Pick = T | { other: int32 };
struct Holder { t: T; n: int32 }
struct S { a: int32; s: string }

function mutT(x: T): void { x.a = 7; }
function mutInline(x: { a: int32 }): void { x.a = 8; }

let failures = 0;
function expect(label: string, got: int32, want: int32): void {
	if (got != want) {
		console.log("FAIL " + label + ": got " + got.toString() + ", want " + want.toString());
		failures += 1;
	}
}

function main(): void {
	const t1: T = { a: 1, s: "x" };
	const t2 = t1;
	t2.a = 2;
	expect("alias", t1.a, 2);

	mutT(t1);
	expect("param write", t1.a, 7);

	const arr: T[] = [{ a: 1, s: "y" }];
	const e = arr[0];
	e.a = 5;
	expect("array element", arr[0].a, 5);

	const h: Holder = { t: t1, n: 0 };
	h.t.a = 9;
	expect("struct field", t1.a, 9);

	const b: Box<int32> = { value: 1 };
	const b2 = b;
	b2.value = 3;
	expect("generic alias", b.value, 3);

	const p: Pick = t1;
	(p as T).a = 11;
	expect("union member", t1.a, 11);

	const lit = { a: 1 };
	const lit2 = lit;
	lit2.a = 4;
	expect("unannotated literal", lit.a, 4);
	mutInline(lit);
	expect("inline annotation", lit.a, 8);

	const s1: S = { a: 1, s: "z" };
	const s2 = s1;
	s2.a = 2;
	expect("struct stays value", s1.a, 1);
}
main();
if (failures == 0) console.log("GUARD-OK");
