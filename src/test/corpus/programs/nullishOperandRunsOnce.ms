// @stdout: map=4 field=3 bare=3 lookups=3 text=hi1 depth=3 arrow=7 cond=yes guard=false loop=2 calls=10
// note: a call in front of `??` or `?.` runs once on every backend: a map lookup, a string result, a recursive routine, an expression-bodied arrow, an if condition, a guarded `&&` and a loop condition.

class Box { f: int32 = 3; }

let calls = 0;
function key(): string { calls = calls + 1; return "a"; }
function text(): string | null { calls = calls + 1; return "hi" + calls.toString(); }
function maybe(v: int32): int32 | null { calls = calls + 1; return v > 0 ? v : null; }

const m = new Map<string, int32>();
m.set("a", 4);
const boxes = new Map<string, Box>();
boxes.set("a", new Box());

const map = m.get(key()) ?? 0;
const field = boxes.get(key())?.f ?? 0;
const bare = boxes.get(key())?.f;
const lookups = calls;
calls = 0;
const t = text() ?? "none";

function depth(n: int32): int32 {
	return (maybe(n > 0 ? depth(n - 1) + 1 : -1) ?? 0);
}
const d = depth(3);
const arrow = (): int32 => maybe(-1) ?? 7;
const a = arrow();
let cond = "no";
if ((maybe(2) ?? 0) > 1) { cond = "yes"; }
let off = false;
const guard = off && (maybe(1) ?? 0) > 0;
let left = 2;
let loop = 0;
while ((maybe(left) ?? 0) > 0) { left = left - 1; loop = loop + 1; }
console.log(`map=${map} field=${field} bare=${bare} lookups=${lookups} text=${t} depth=${d} arrow=${a} cond=${cond} guard=${guard} loop=${loop} calls=${calls}`);
