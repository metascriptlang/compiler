// @stdout: e1 e1 e1
// @stdout: x1 x1 x1
// note: a struct literal whose Vec field is written after the zero shell holds one array, not a zero array plus the written one, with a class element and with a reassignment on top
class Tok {
	s: string;
	constructor(s: string) { this.s = s; }
}
struct Holder {
	rows: Vec<Tok>;
	k: int32;
}
struct Names {
	rows: Vec<string>;
	k: int32;
}
function once(k: int32): string {
	let h: Holder = { rows: [new Tok("z")], k: k };
	return "e" + h.rows.length.toString();
}
function twice(k: int32): string {
	let h: Names = { rows: ["a".repeat(2)], k: k };
	h.rows = ["b".repeat(2)];
	return "x" + h.rows.length.toString();
}
const first: string[] = [];
const second: string[] = [];
for (let k: int32 = 0; k < 3; k += 1) {
	first.push(once(k));
	second.push(twice(k));
}
console.log(first.join(" "));
console.log(second.join(" "));
