// @stdout: two 7 9 0
// @stdout: three 7 9 0 11
// @stdout: expr 7 9 0
// @stdout: enum 7 9 0 7 9 3
// note: a match arm with `|` alternatives on a union discriminant narrows the value to the union of the variants its alternatives select, as a single-tag arm narrows to one variant. Before, an arm with more than one pattern kept the whole union, so a field shared by the selected variants was refused as existing only on some variants.
struct A { kind: "a"; tile: int32; }
struct B { kind: "b"; tile: int32; }
struct C { kind: "c"; other: int32; }
struct D { kind: "d"; tile: int32; }
function two(value: A | B | C): int32 {
	match (value.kind) {
		"a" | "b" => { return value.tile; }
		_ => { return 0; }
	}
}
function three(value: A | B | C | D): int32 {
	match (value.kind) {
		"a" | "b" | "d" => { return value.tile; }
		_ => { return 0; }
	}
}
function expr(value: A | B | C): int32 {
	return match (value.kind) {
		"a" | "b" => value.tile,
		_ => 0,
	};
}
enum K { A, B, C }
type Shape = match (kind: K) {
	K.A => { tile: int32 },
	K.B => { tile: int32 },
	K.C => { other: string },
};
function pick(s: Shape): int32 {
	match (s.kind) {
		K.A | K.B => { return s.tile; }
		_ => { return 0; }
	}
}
function pickExpr(s: Shape): int32 {
	return match (s.kind) {
		K.A | K.B => s.tile,
		K.C => s.other.length as int32,
	};
}
const a: A = { kind: "a", tile: 7 };
const b: B = { kind: "b", tile: 9 };
const c: C = { kind: "c", other: 5 };
const d: D = { kind: "d", tile: 11 };
console.log("two", two(a), two(b), two(c));
console.log("three", three(a), three(b), three(c), three(d));
console.log("expr", expr(a), expr(b), expr(c));
const sa: Shape = { kind: K.A, tile: 7 };
const sb: Shape = { kind: K.B, tile: 9 };
const sc: Shape = { kind: K.C, other: "xyz" };
console.log("enum", pick(sa), pick(sb), pick(sc), pickExpr(sa), pickExpr(sb), pickExpr(sc));
