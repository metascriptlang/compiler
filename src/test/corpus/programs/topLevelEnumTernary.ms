// @stdout: a a a b a a b a
// note: a top-level binding initialised from a ternary, `??` or match whose value is an enum member built on C with the module init assigning `MS_NIL` to the enum slot. Variants: const, let, annotated, arm of a typed variable, explicit values, `??`, match, both arms equal.

enum Kind { A, B }
enum Tag { A = 5, B = 9 }
const flip = "ab".length > 1;
const other: Kind = Kind.B;

const viaConst = flip ? Kind.A : Kind.B;
let viaLet = flip ? Kind.A : Kind.B;
const annotated: Kind = flip ? Kind.A : Kind.B;
const withVar = flip ? Kind.A : other;
const flipped = !flip ? Kind.A : Kind.B;
const explicit = flip ? Tag.A : Tag.B;
const maybe: Kind | null = flip ? Kind.A : null;
const viaCoalesce = maybe ?? Kind.B;
const viaMatch: Kind = match (other) { Kind.A => Kind.B, Kind.B => Kind.A };
const same = flip ? Kind.A : Kind.A;

function name(k: Kind): string { return k == Kind.A ? "a" : "b"; }

console.log(
	name(viaConst),
	name(viaLet),
	name(annotated),
	name(flipped),
	name(withVar),
	name(viaCoalesce),
	explicit == Tag.A ? "b" : "a",
	name(viaMatch),
);
