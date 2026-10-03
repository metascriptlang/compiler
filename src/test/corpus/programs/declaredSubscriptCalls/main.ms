// @stdout: 103 107|8 7|xy|24|12 21
// note: a declared `[]` / `[]=` is an ordinary call of the routine: a struct value and a `ref`
// receiver, a class, a generic receiver and an operator imported with its type from another module.
import { Grid } from "./lib/grid";

struct P { v: int32; }
function `[]`(this self: P, i: int32): int32 { return i + self.v; }
function `[]=`(this ref self: P, i: int32, x: int32): void { self.v = i + x; }

class Counter { v: int32 = 1; }
function `[]`(this c: Counter, i: int32): int32 { return i * 10 + c.v; }
function `[]=`(this c: Counter, i: int32, x: int32): void { c.v = i + x; }

struct Pair<T> { a: T; b: T; }
function `[]`<T>(this self: Pair<T>, i: int32): T { return i == 0 ? self.a : self.b; }

const out: string[] = [];
let p: P = { v: 100 };
const before = p[3];
p[3] = 4;
out.push(`${before} ${p[0] + 100}`);

const c = new Counter();
c[3] = 4;
out.push(`${c[0] + 1} ${c.v}`);

const pair: Pair<string> = { a: "x", b: "y" };
out.push(pair[0] + pair[1]);

let g: Grid = { w: 2, cells: [1, 2, 3] };
g[1] = 20;
out.push(`${g[0] + g[1] + g[2]}`);

const ps: P[] = [{ v: 10 }, { v: 20 }];
out.push(`${ps[0][2]} ${ps[1][1]}`);
console.log(out.join("|"));
