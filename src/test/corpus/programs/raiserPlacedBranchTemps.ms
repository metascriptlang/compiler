// @stdout: b:1 z big9 mid4 small n3 kept t7 u
// note: a string a branch of a conditional builds is released on the path that ran, by the branch's own scope: a ternary, a nested ternary, `??` on strings, and an arm that is a struct cell.

struct Cell { tag: string; n: int32; }

function pick(c: boolean, n: number): string { return c ? "b:" + n.toString() : "z"; }
function nested(a: number): string { return a > 5 ? "big" + a.toString() : a > 2 ? "mid" + a.toString() : "small"; }
function orNull(s: string | null, n: number): string { return s ?? "n" + n.toString(); }
function cellOf(c: boolean, n: number): Cell { return c ? { tag: "t" + n.toString(), n: 1 } : { tag: "u", n: 2 }; }

function main(): void {
	const out: string[] = [];
	out.push(pick(true, 1));
	out.push(pick(false, 2));
	out.push(nested(9));
	out.push(nested(4));
	out.push(nested(1));
	out.push(orNull(null, 3));
	out.push(orNull("kept", 3));
	const a = cellOf(true, 7);
	const b = cellOf(false, 8);
	out.push(a.tag);
	out.push(b.tag);
	console.log(out.join(" "));
}
main();
