// note: hooks-vec-tuple. A Vec<T> whose element is a tuple (`Vec<[string, int32]>`, a POD `Vec<[int32, int32]>`, an alias `Vec<Row>`, a tuple holding a class or a Vec) was destroyed as an array of pointers: a panic at scope exit, or a C type error on copy. Fix (08475b5b): the analyzer takes the tuple array's own hooks. Built, copied, sunk over, stored in a struct field and returned.

class Tok {
	s: string;
	constructor(s: string) { this.s = s; }
}

type Row = [Tok, int32];

struct Holder {
	rows: Vec<Row>;
	k: int32;
}

function mk(n: int32): Vec<[Tok, int32]> {
	const out: Vec<[Tok, int32]> = [];
	for (let i: int32 = 0; i < n; i += 1) out.push([new Tok("r" + i.toString()), i]);
	return out;
}

function round(k: int32): string {
	let xs = mk(3);
	const ys = xs;
	xs = mk(2);
	const h: Holder = { rows: [], k: k };
	h.rows.push([new Tok("h" + k.toString()), 7 as int32]);
	h.rows = [[new Tok("i" + k.toString()), 8 as int32], [new Tok("j" + k.toString()), 9 as int32]];
	const named: Vec<[string, int32]> = [];
	named.push(["s" + k.toString(), k]);
	const pod: Vec<[int32, int32]> = [];
	pod.push([k, k + 1]);
	const nest: Vec<[Vec<Row>, string]> = [];
	nest.push([h.rows, "n" + k.toString()]);
	return xs.length.toString() + " " + ys[2][0].s + " " + h.rows[1][0].s + " " + named[0][0] + " " + pod[0][1].toString() + " " + nest[0][0][0][0].s + nest[0][1];
}

function run(): void {
	for (let k: int32 = 0; k < 3; k += 1) console.log(round(k));
}
run();
