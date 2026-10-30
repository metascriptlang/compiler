// @stdout: m|m!,7,2
// @stdout: given,7,3
// @stdout: g,7,4
// @stdout: m|m!;mz,6
// @stdout: x;mz,7
let calls = 0;
function make(): string { calls += 1; return "m"; }
function inner(a: string, b: string = a + "!"): string { return a + "|" + b; }
struct P { x: int32; y: int32 }
function mkP(): P { calls += 1; return { x: 7, y: 8 }; }
function withDefaults(s: string = inner(make()), p: P = mkP()): string { return s + "," + p.x.toString() + "," + calls.toString(); }
class C { m(s: string = inner(make()), t: string = make() + "z"): string { return s + ";" + t + "," + calls.toString(); } }

console.log(withDefaults());
console.log(withDefaults("given"));
console.log(withDefaults("g", mkP()));
console.log(new C().m());
console.log(new C().m("x"));
