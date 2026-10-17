// @stdout: tpl null null null null null
// note: null prints as "null" on every backend, through console.log, a template, String() and
// concatenation on either side, for nullable string, integer, float, boolean and an array element.
// The Raiser printed "nil".

const s: string | null = null;
const n: int32 | null = null;
const f: number | null = null;
const b: boolean | null = null;
const xs: (number | null)[] = [1, null];

console.log(s);
console.log(n, f, b);
console.log(`tpl ${s} ${n} ${f} ${b} ${xs[1]}`);
console.log("str " + String(s) + " " + String(n) + " " + String(f) + " " + String(b) + " " + String(xs[1]));
console.log("cat " + s + " " + n + " " + f + " " + b + " " + xs[1]);
console.log(s + " first");
