// bug157 — a generic call stored into a nullable slot was instantiated without the slot's payload type
//
// Symptom:    `const p: P = { a: accessor(() => 122) }` with `a?: Acc<number> | null` read back as
//             `2.12e-314` on C (js printed 122): `accessor<T>` was instantiated with `T = int32` from
//             the literal, the resulting `Acc<int32>` was accepted into the `Acc<number>` payload, and
//             the closure returned an int where the reader loaded a double. Found by Neon's Pressable:
//             `delayLongPress={120}` fired the long press immediately.
//
// Root cause: contextual return-type binding unified `Acc<T>` against the Maybe wrapper instead of
//             its payload, and the GenericInstance assignability arm compared type arguments
//             covariantly, so `Acc<int32>` flowed into `Acc<number>` although the closure ABI differs.
//
// Fix:        unifyType peels a Maybe on the concrete side (like the Union<T,null> bridge) so the
//             payload binds `T`; a nominal (distinct-backed) instance requires identical arguments.

type Acc157<T> = distinct (() => T);
export function valueOf<T>(this a: Acc157<T>): T { return a(); }
function accessor157<T>(f: () => T): Acc157<T> { return f as Acc157<T>; }
interface P157 { a?: Acc157<number> | null; s?: Acc157<string> | null; }

function readA157(p: P157): number { if (p.a != null) { return p.a + 0; } return -1; }
function readS157(p: P157): string { if (p.s != null) { return p.s; } return "-"; }
function withDefault157(p: P157): number { const { a = accessor157(() => 500) } = p; return a + 0; }

test "bug157: a generic call in a nullable slot carries the payload's type" {
	const p: P157 = { a: accessor157(() => 122), s: accessor157(() => "z") };
	assert readA157(p) === 122;
	assert readS157(p) === "z";
}

test "bug157: a destructuring default in the slot's type reads the given value" {
	const given: P157 = { a: accessor157(() => 120), s: null };
	const none: P157 = { a: null, s: null };
	assert withDefault157(given) === 120;
	assert withDefault157(none) === 500;
}

test "bug157: an explicitly typed instance still flows" {
	const c = accessor157<number>(() => 7);
	const p: P157 = { a: c, s: null };
	assert readA157(p) === 7;
}
