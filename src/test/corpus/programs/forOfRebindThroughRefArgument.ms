// @stdout: x0 x1 x2|123|123|123|123|a,b,c

function reset(ref r: string[]): void { r = ["n0-heap-string-long-enough-xx", "n1-heap-string-long-enough-xx", "n2-heap-string-long-enough-xx"]; }
function resetN(ref r: int32[], n: int32): void { const t: int32[] = []; for (let i = 0; i < n; i++) t.push(9); r = t; }
function resetExt(this ref r: int32[]): void { r = [7, 7, 7]; }
function mk(): string[] { const r: string[] = []; for (let i = 0; i < 3; i++) r.push("x" + String(i) + "-heap-string-long-enough-xx"); return r; }
function strings(): string { let a = mk(); const seen: string[] = []; for (const s of a) { reset(a); seen.push(s.slice(0, 2)); } return seen.join(" "); }
function same(): string { let a: int32[] = [1, 2, 3]; let s = ""; for (const x of a) { s += String(x); resetN(a, 3); } return s; }
function shorter(): string { let a: int32[] = [1, 2, 3]; let s = ""; try { for (const x of a) { s += String(x); resetN(a, 1); } } catch (e) { s += "|threw"; } return s; }
function ext(): string { let a: int32[] = [1, 2, 3]; let s = ""; for (const x of a) { s += String(x); a.resetExt(); } return s; }
function nested(): string { let a: int32[] = [1, 2, 3]; let s = ""; for (const x of a) { for (const y of a) { if (y == 1) resetN(a, 3); } s += String(x); } return s; }
function pairs(): string { let a: [string, int32][] = [["a", 1], ["b", 2], ["c", 3]]; const seen: string[] = []; for (const [k, v] of a) { seen.push(k); rp(a); } return seen.join(","); }
function rp(ref r: [string, int32][]): void { r = [["z", 0], ["z", 0], ["z", 0]]; }
console.log(strings() + "|" + same() + "|" + shorter() + "|" + ext() + "|" + nested() + "|" + pairs());
