// @stdout: 3 w null | 3|null|w | 7 v null | 3null 2 | 2.5 x null
// @stdout: 3 w null
// note: a union with a null member turns into text through the member it holds, or "null" when absent, in a template, String(), concatenation and console.log, for a float and an int32 member, and the operand runs once.

function either(k: int32): number | string | null { return k == 0 ? 3 : (k == 1 ? "w" : null); }
function narrow(k: int32): int32 | string | null { return k == 0 ? 7 : (k == 1 ? "v" : null); }
let calls = 0;
function counted(k: int32): number | string | null { calls += 1; return either(k); }
class Slot { v: number | string | null = null; }

const u = either(0);
const w = either(1);
const n = either(2);
const s = new Slot();
const parts: string[] = [];
parts.push(`${u} ${w} ${n}`);
parts.push(String(u) + "|" + String(n) + "|" + w);
parts.push(`${narrow(0)} ${narrow(1)} ${narrow(2)}`);
parts.push(`${counted(0)}${counted(2)} ${calls}`);
s.v = 2.5;
const a = `${s.v}`;
s.v = "x";
const b = `${s.v}`;
s.v = null;
parts.push(`${a} ${b} ${s.v}`);
console.log(parts.join(" | "));
console.log(u, w, n);
