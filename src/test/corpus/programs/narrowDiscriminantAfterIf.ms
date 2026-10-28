// @stdout: 4 4 3 5
// note: a discriminant `if` that falls through leaves the declared union at the join, so the next `if` on the discriminant narrows again; two and three sequential ifs, and a join of a nested if.

enum Kind { Dot, Square, Label }
struct Shape = match (kind: Kind) {
	Kind.Dot => {},
	Kind.Square => { side: int32 },
	Kind.Label => { text: string },
};

function two(s: Shape): int32 {
	let n: int32 = 0;
	if (s.kind == Kind.Dot) { n = 1; }
	if (s.kind == Kind.Square) { n = s.side; }
	return n;
}
function three(s: Shape): int32 {
	let n: int32 = 0;
	if (s.kind == Kind.Dot) { n = 1; }
	if (s.kind == Kind.Square) { n = s.side; }
	if (s.kind == Kind.Label) { n = s.text.length; }
	return n;
}
function nested(s: Shape, deep: boolean): int32 {
	let n: int32 = 0;
	if (s.kind != Kind.Dot) {
		if (deep) { n = 1; }
	}
	if (s.kind == Kind.Square) { n = n + s.side; }
	return n;
}

const sq: Shape = { kind: Kind.Square, side: 4 };
const lb: Shape = { kind: Kind.Label, text: "abc" };
console.log(two(sq), three(sq), three(lb), nested(sq, true));
