// @stdout: sync null 3 null 4 | null a null b | null 7 null 8 | null 5 null 6
// @stdout: nested null 1 null 2 | arrow null 9 null 10 | declared null 11
// @stdout: void ok
// @stdout: async null 3 | null a | null 7 | then null 3
// note: a function without a return annotation that mixes `return;` with `return <value>;` returns `T | null`, and the bare return gives null on every backend. Covers int32, string and a class value, a bare return before and after the value return, one nested in a loop and a branch, an arrow, `return null` beside a value in an arrow, an annotated `int32 | null`, and async through await and `.then`.
class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

function show(b: Box | null): string {
	return b == null ? "null" : `${b.v}`;
}

function bareFirst(c: boolean) { if (c) return; return 3; }
function valueFirst(c: boolean) { if (!c) return 4; return; }
function text(c: boolean, s: string) { if (c) return; return s; }
function box(c: boolean, v: int32) { if (c) return; return new Box(v); }

function nested(n: int32) {
	for (let i = 0; i < 3; i++) {
		if (i == n) {
			if (n > 0) return i;
			else return;
		}
	}
	return n * 2 - 2;
}

const arrow = (c: boolean, v: int32) => { if (c) return; return v; };
const arrowNull = (c: boolean, v: int32) => { if (c) return null; return v; };
function declared(c: boolean): int32 | null { if (c) return; return 11; }
function onlyBare(c: boolean) { if (c) return; console.log("void ok"); }

console.log(`sync ${bareFirst(true)} ${bareFirst(false)} ${valueFirst(true)} ${valueFirst(false)} | ${text(true, "a")} ${text(false, "a")} ${text(true, "b")} ${text(false, "b")} | ${show(box(true, 7))} ${show(box(false, 7))} ${show(box(true, 8))} ${show(box(false, 8))} | ${arrowNull(true, 5)} ${arrowNull(false, 5)} ${arrowNull(true, 6)} ${arrowNull(false, 6)}`);
console.log(`nested ${nested(0)} ${nested(1)} ${nested(0)} ${nested(2)} | arrow ${arrow(true, 9)} ${arrow(false, 9)} ${arrow(true, 10)} ${arrow(false, 10)} | declared ${declared(true)} ${declared(false)}`);
onlyBare(false);

async function mk(c: boolean) { await sleepAsync(0); if (c) return; return 3; }
async function mkText(c: boolean) { await sleepAsync(0); if (c) return; return "a"; }
async function mkBox(c: boolean) { await sleepAsync(0); if (c) return; return new Box(7); }

async function run(): Promise<void> {
	let s = "";
	await mk(true).then((v): void => { s += `${v}`; });
	await mk(false).then((v): void => { s += ` ${v}`; });
	console.log(`async ${await mk(true)} ${await mk(false)} | ${await mkText(true)} ${await mkText(false)} | ${show(await mkBox(true))} ${show(await mkBox(false))} | then ${s}`);
}
await run();
