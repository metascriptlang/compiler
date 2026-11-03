// @stdout: a-xx32 ap-x33 am-x33 ab-x33 ab-x33

// ref param of a class, a struct and a Map; the callee rebinds its own ref param
function fresh(tag: string): string { return tag + "-" + "x".repeat(30); }
class Cell { s: string = ""; }
function newCell(t: string): Cell { const c = new Cell(); c.s = fresh(t); return c; }
function swapCell(ref d: Cell): void { d = newCell("n"); }
function fieldThenSwap(ref c: Cell): string { const t = c.s; swapCell(c); return t.substring(0, 4) + t.length.toString(); }
struct P { name: string; n: int64; }
function setP(ref q: P): void { q = { name: fresh("np"), n: 2 }; }
function structField(ref p: P): string { const t = p.name; setP(p); return t.substring(0, 4) + t.length.toString(); }
function clearM(ref mm: Map<string, string>): void { mm = new Map<string, string>(); mm.set("k", fresh("nm")); }
function mapGet(ref m: Map<string, string>): string { const v = m.get("k")!; clearM(m); return v.substring(0, 4) + v.length.toString(); }
class Box { items: string[] = []; }
function refill(ref b: Box): void { b = new Box(); b.items = [fresh("nb")]; }
function deepPath(ref b: Box): string { const t = b.items[0]; refill(b); return t.substring(0, 4) + t.length.toString(); }
function replaceItems(ref xs: string[]): void { xs = [fresh("ni")]; }
function fieldForward(b: Box): string { const t = b.items[0]; replaceItems(b.items); return t.substring(0, 4) + t.length.toString(); }
let gc = newCell("a");
let gp: P = { name: fresh("ap"), n: 1 };
let gm = new Map<string, string>();
gm.set("k", fresh("am"));
let gb = new Box();
gb.items = [fresh("ab")];
const r1 = fieldThenSwap(gc);
const r2 = structField(gp);
const r3 = mapGet(gm);
const r4 = deepPath(gb);
gb.items = [fresh("ab")];
const r5 = fieldForward(gb);
console.log(`${r1} ${r2} ${r3} ${r4} ${r5}`);
