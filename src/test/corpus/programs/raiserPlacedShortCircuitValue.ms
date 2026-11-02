// @stdout: or=e5,t,e5 and=,e5 calls=1,1 cell=e2,kept chain=e3,b,c sink=e4
struct Wrap { label: string; }
let calls = 0;
function label(s: string): string { calls += 1; return s; }
function wrapOf(s: string): Wrap { calls += 1; return { label: s }; }

function orEmpty(s: string, n: int32): string { return s || "e" + n.toString(); }
function andNext(s: string, n: int32): string { return s && "e" + n.toString(); }
function chain(a: string, b: string, n: int32): string { return a || b || "e" + n.toString(); }
function viaCell(s: string, n: int32): string { return wrapOf(s).label || "e" + n.toString(); }
function viaSink(s: string, n: int32): string { const out: string[] = []; out.push(s || "e" + n.toString()); return out[0]; }

const o = `${orEmpty("", 5)},${orEmpty("t", 5)},${orEmpty("", 5)}`;
const a = `${andNext("", 5)},${andNext("t", 5)}`;
calls = 0;
label("") || "x" + calls.toString();
const once = calls;
calls = 0;
(label("v") && "w" + calls.toString());
const once2 = calls;
const c = `${viaCell("", 2)},${viaCell("kept", 2)}`;
const ch = `${chain("", "", 3)},${chain("", "b", 3)},${chain("c", "b", 3)}`;
console.log(`or=${o} and=${a} calls=${once},${once2} cell=${c} chain=${ch} sink=${viaSink("", 4)}`);
