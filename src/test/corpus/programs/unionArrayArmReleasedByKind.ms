// @stdout: 3 s 2 7 x 1
// @stdout: 4 s 5
// note: a union with an array, fixed-array or tuple member holds that member itself, beside a string or a number, with no tag. Releasing it frees whichever member it holds, at the end of a function as at the end of the program.
struct Pt { x: int32, y: int32 }
function list(k: int32): int32[] | string { return k == 0 ? [1, 2, 3] : "s"; }
function pair(k: int32): Pt[2] | int32 { return k == 0 ? [{ x: 1, y: 2 }, { x: 3, y: 4 }] : 7; }
function tup(k: int32): [string, int32] | string {
	const t: [string, int32] = ["x", 1];
	return k == 0 ? t : "y";
}
function lengthOf(v: int32[] | string): int32 { return typeof v == "string" ? 0 : v.length; }

const a = list(0);
const b = list(1);
const c = pair(0);
const d = pair(1);
const e = tup(0);
console.log(lengthOf(a), b, typeof c == "number" ? 0 : c.length, d, typeof e == "string" ? e : e[0], typeof e == "string" ? 0 : e[1]);

function inFunction(): string {
	const l = list(0);
	const s = list(1);
	const p = pair(0);
	return `${lengthOf(l) + 1} ${s} ${typeof p == "number" ? p : p[0].x + p[1].x + 1}`;
}
console.log(inFunction());
