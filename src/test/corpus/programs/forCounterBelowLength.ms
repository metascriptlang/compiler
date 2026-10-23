// @stdout: 6 0 9 0 15 0 30 0
// @stdout: grew caught 1
// @stdout: shrank caught 1
// @stdout: indexed 31
// @stdout: wide 4 narrow 3
// note: an int32 counter below an int32 bound, a for-of over an int32 or int64 array, an empty array, and an array that
// grows or shrinks under the loop give the same result on every backend; the length check of for-of still stops them.

function sumIndexed(a: int32[]): int64 { let s: int64 = 0; for (let i: int32 = 0; i < a.length; i++) s += a[i]; return s; }
function sumWide(a: int64[]): int64 { let s: int64 = 0; for (let i: int64 = 0; i < a.length; i = i + 1) s += a[i]; return s; }
function each32(a: int32[]): int64 { let s: int64 = 0; for (const x of a) s += x; return s; }
function each64(a: int64[]): int64 { let s: int64 = 0; for (const x of a) s += x; return s; }
function grow(a: int64[]): int64 { let s: int64 = 0; for (const x of a) { s += x; if (x == 1) a.push(9); } return s; }
function shrink(a: int32[]): int64 { let s: int64 = 0; for (const x of a) { s += x; a.pop(); } return s; }
function growIndexed(a: int32[]): int64 { let s: int64 = 0; for (let i: int32 = 0; i < a.length; i++) { s += a[i]; if (i < 3) a.push(10); } return s; }
function widen(n: int32, m: int64): string {
	let wide: int64 = 0;
	let narrow: int32 = 0;
	for (let i: int32 = 0; i < n; i++) { wide += i; narrow += i; }
	for (let j: int64 = 0; j < m; j++) { wide += j; }
	return `wide ${wide} narrow ${narrow}`;
}

const e32: int32[] = [];
const e64: int64[] = [];
console.log(`${sumIndexed([1, 2, 3])} ${sumIndexed(e32)} ${sumWide([4, 5])} ${sumWide(e64)} ${each32([7, 8])} ${each32(e32)} ${each64([9, 10, 11])} ${each64(e64)}`);
try { grow([1, 2]); console.log("grew"); } catch (e) { console.log("grew caught 1"); }
try { shrink([1, 2, 3]); console.log("shrank"); } catch (e) { console.log("shrank caught 1"); }
console.log(`indexed ${growIndexed([1])}`);
console.log(widen(3, 2));
