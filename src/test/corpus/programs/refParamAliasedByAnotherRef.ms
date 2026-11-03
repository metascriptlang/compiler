// @stdout: a1-xxx33 a1-xxx33 a1-xxx33 ss-xxx33 ss-xxx33

// two ref params bound to the same variable
function fresh(tag: string): string { return tag + "-" + "x".repeat(30); }
function replace(ref ys: string[]): void { ys = [fresh("n0"), fresh("n1")]; }
function cursorThenAssign(ref a: string[], ref b: string[]): string { const s = a[1]; b = [fresh("z0"), fresh("z1")]; return s.substring(0, 6) + s.length.toString(); }
function cursorThenForward(ref a: string[], ref b: string[]): string { const s = a[1]; replace(b); return s.substring(0, 6) + s.length.toString(); }
function show(s: string, ref ys: string[]): string { ys = [fresh("m0"), fresh("m1")]; return s.substring(0, 6) + s.length.toString(); }
function argThenForward(ref a: string[], ref b: string[]): string { return show(a[1], b); }
function strAlias(ref a: string, ref b: string): string { const t = a; b = fresh("zz"); return t.substring(0, 6) + t.length.toString(); }
function setStr(ref s: string): void { s = fresh("qq"); }
function strForward(ref a: string, ref b: string): string { const t = a; setStr(b); return t.substring(0, 6) + t.length.toString(); }
let g: string[] = [fresh("a0"), fresh("a1")];
const r1 = cursorThenAssign(g, g);
g = [fresh("a0"), fresh("a1")];
const r2 = cursorThenForward(g, g);
g = [fresh("a0"), fresh("a1")];
const r3 = argThenForward(g, g);
let s = fresh("ss");
const r4 = strAlias(s, s);
s = fresh("ss");
const r5 = strForward(s, s);
console.log(`${r1} ${r2} ${r3} ${r4} ${r5}`);
