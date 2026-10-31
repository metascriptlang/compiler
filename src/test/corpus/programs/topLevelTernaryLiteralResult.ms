// @stdout: true x true b 7 3 none y q
// note: a top-level binding annotated with a literal type or a scalar and initialised from a ternary or `??` built on C with the module init assigning `MS_NIL` to its slot. Variants: enum literal, string literal, `true`, enum, number literal, number, nullable, `??`, and the same inside a function.

enum Kind { A, B }
const flip = "ab".length > 1;
const maybe: number | null = flip ? null : 1;

const enumLit: Kind.A = flip ? Kind.A : Kind.A;
const strLit: "x" = flip ? "x" : "x";
const yes: true = flip ? true : true;
const kind: Kind = flip ? Kind.B : Kind.A;
const numLit: 7 = flip ? 7 : 7;
const num: number = flip ? 3 : 4;
const viaNullish: number | string = maybe ?? "none";
const nullableLit: "y" | null = flip ? "y" : null;
const viaCoalesceLit: "y" = nullableLit ?? "y";

function inside(): string {
	const s: "q" = flip ? "q" : "q";
	return s;
}

console.log(
	enumLit == Kind.A,
	strLit,
	yes,
	kind == Kind.B ? "b" : "a",
	numLit,
	num,
	viaNullish,
	viaCoalesceLit,
	inside(),
);
