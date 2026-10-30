// @stdout: ok|ok|ok|ok|ok|true false true false
struct P { v: int32; }
function wf(): float32 | string | null { return 320.0 as float32; }
function wn(): number | string | null { return 320.0; }
function u(a: P | string, b: P): boolean { return a == b; }
function w(a: P | string): boolean { return a == "s"; }

const x = wf() ?? 0.0;
const b: number | string = wn() ?? 0.0;
const p: P = { v: 1 };
console.log([
	x === 320.0 ? "ok" : "bad",
	(wn() ?? 0.0) === 320.0 ? "ok" : "bad",
	b === 320.0 ? "ok" : "bad",
	(wn() ?? "s") === 320.0 ? "ok" : "bad",
	((): string => { const n: number | string | null = null; return (n ?? 320.0) === 320.0 ? "ok" : "bad"; })(),
	[u(p, p), u("x", p), w("s"), w(p)].join(" "),
].join("|"));
