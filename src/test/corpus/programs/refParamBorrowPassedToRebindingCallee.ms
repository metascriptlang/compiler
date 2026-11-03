// @stdout: ss-xxx33 ss-xxx33 gc-xxx33 gc-xxx33 gn-xxx33 qq nd

// a string or class borrowed from a ref param and passed to a callee that rebinds an aliasing ref param
function fresh(tag: string): string { return tag + "-" + "x".repeat(30); }
function showAfter(s: string, ref t: string): string { t = fresh("tt"); return s.substring(0, 6) + s.length.toString(); }
function strArg(ref a: string, ref b: string): string { return showAfter(a, b); }
function setStr(ref s: string): void { s = fresh("qq"); }
function strCursor(ref a: string): string { const t = a; setStr(a); return t.substring(0, 6) + t.length.toString(); }
class Cell { s: string = ""; }
function newCell(t: string): Cell { const c = new Cell(); c.s = fresh(t); return c; }
function showCell(s: string, ref e: Cell): string { e = newCell("nc"); return s.substring(0, 6) + s.length.toString(); }
function cellArg(ref c: Cell, ref d: Cell): string { return showCell(c.s, d); }
function holdCell(c: Cell, ref e: Cell): string { e = newCell("nd"); return c.s.substring(0, 6) + c.s.length.toString(); }
function cellWhole(ref c: Cell, ref d: Cell): string { return holdCell(c, d); }
function clearCell(ref d: Cell | null): void { d = null; }
function nullable(ref c: Cell | null): string { const t = c!.s; clearCell(c); return t.substring(0, 6) + t.length.toString(); }
let s = fresh("ss");
const r1 = strArg(s, s);
s = fresh("ss");
const r2 = strCursor(s);
let gc = newCell("gc");
const r3 = cellArg(gc, gc);
gc = newCell("gc");
const r4 = cellWhole(gc, gc);
let gn: Cell | null = newCell("gn");
const r5 = nullable(gn);
console.log(`${r1} ${r2} ${r3} ${r4} ${r5} ${s.substring(0, 2)} ${gc.s.substring(0, 2)}`);
