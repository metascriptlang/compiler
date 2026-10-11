// @stdout: narrowed=4 named=5 class=3 text=hi value=7 calls=5,1 shape=6,11
// note: `x?.f` on an object whose type holds no null reads the field like `x.f`, as in TS: the read is not tested against null. An inline shape narrowed by a null test, a named shape, a class, a string field, a value struct and a call result read once all give the field.

interface Named { v: int32 }
class Leaf { v: int32 = 3; }
struct Point { x: int32; }

function inlineOrNull(on: boolean): { deep: { v: int32 } } | null { return on ? { deep: { v: 4 } } : null; }
function namedOrNull(on: boolean): Named | null { return on ? { v: 5 } : null; }
function leafOrNull(on: boolean): Leaf | null { return on ? new Leaf() : null; }

let calls = 0;
function named(): Named { calls = calls + 1; return { v: 5 }; }
function shape(): { v: int32 } { calls = calls + 10; return { v: 6 }; }

function narrowed(): int32 {
	const x = inlineOrNull(true);
	if (x != null) return x?.deep.v ?? 0;
	return -1;
}

function byName(): int32 {
	const y = namedOrNull(true);
	if (y != null) return y?.v ?? 0;
	return -1;
}

function byClass(): int32 {
	const k = leafOrNull(true);
	if (k != null) return k?.v ?? 0;
	return -1;
}

function text(): string {
	const e: { n: string } | null = { n: "hi" };
	return e?.n ?? "-";
}

const p: Point = { x: 7 };
const once = `${named()?.v ?? 0},${calls}`;
const twice = `${shape()?.v ?? 0},${calls}`;
console.log(`narrowed=${narrowed()} named=${byName()} class=${byClass()} text=${text()} value=${p?.x} calls=${once} shape=${twice}`);
