// @skip-js: the JS backend leaves grown slots undefined (inbox 2026-10-12-js-array-setlength-grow-leaves-undefined-slots)
// @xfail(raiser): the Raiser VM refuses `a.length = n` on an int32[] with "expected an object, got value kind Array" (base compiler too)
// @stdout: int32 1 2 0 0 0 0 0 0
// @stdout: uint8 1 2 0 0 0 0 0 0
// @stdout: int16 1 2 0 0 0 0 0 0
// @stdout: float32 1 2 0 0 0 0 0 0
// @stdout: int64 1 2 0 0 0 0 0 0
// @stdout: float64 1 0 0 0
// @stdout: number 1 0 0 0
// @stdout: setLength int32 1 0 0 0
function regrow<T>(a: T[], keep: int32, total: int32): void {
	a.setLength(keep);
	a.setLength(total);
}

const a: int32[] = [1, 2, 3, 4, 5, 6, 7, 8];
a.length = 2;
a.length = 8;
console.log("int32 " + a.join(" "));
const b: uint8[] = [1, 2, 3, 4, 5, 6, 7, 8];
b.length = 2;
b.length = 8;
console.log("uint8 " + b.join(" "));
const c: int16[] = [1, 2, 3, 4, 5, 6, 7, 8];
c.length = 2;
c.length = 8;
console.log("int16 " + c.join(" "));
const f: float32[] = [1, 2, 3, 4, 5, 6, 7, 8];
f.length = 2;
f.length = 8;
console.log("float32 " + f.join(" "));
const g: int64[] = [1, 2, 3, 4, 5, 6, 7, 8];
g.length = 2;
g.length = 8;
console.log("int64 " + g.join(" "));
const n: float64[] = [1, 2, 3, 4];
n.length = 1;
n.length = 4;
console.log("float64 " + n.join(" "));
const m: number[] = [1, 2, 3, 4];
m.length = 1;
m.length = 4;
console.log("number " + m.join(" "));
const s: int32[] = [1, 2, 3, 4];
regrow(s, 1, 4);
console.log("setLength int32 " + s.join(" "));
