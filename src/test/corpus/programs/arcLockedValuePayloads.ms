// @stdout: str=5 up=HELLO int=42 pt=7/3
// @stdout: re=5 rep=world/5
// @stdout: lk=2
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: Arc<T> over a value payload (string, int32, struct) and Locked<T> over a plain struct build and run with one result on C and JS. A string pointee reads `.length` without an explicit `[]`; a call takes `[]`; an int32 pointee reads through `[]`; a second Arc handle is created while a spawn still reads the first.

import { lockedRead, lockedUpdate } from "std/core/promise";

struct Point { x: int32; y: int32; }
struct Idx { head: int32; tail: int32; }

async function main(): Promise<void> {
	const s: Arc<string> = new Arc("hello");
	const n: Arc<int32> = new Arc(41);
	const p: Arc<Point> = new Arc({ x: 3, y: 4 });
	const len = spawn(() => s.length);
	const up = spawn(() => s[].toUpperCase());
	const inc = spawn(() => n[] + 1);
	const pt = spawn(() => p.y + p.x);
	console.log(`str=${await len} up=${await up} int=${await inc} pt=${await pt}/${p.y - 1}`);
	const r: Arc<string> = new Arc("hello");
	const before = spawn(() => r.length);
	const r2: Arc<string> = new Arc("world");
	const after = spawn(() => r2[]);
	console.log(`re=${await before} rep=${await after}/${r2.length}`);
	const l = new Locked<Idx>({ head: 0, tail: 0 });
	const bump = spawn(() => { lockedUpdate(l, (v: Idx): Idx => ({ head: v.head + 1, tail: v.tail })); return 0; });
	const bump2 = spawn(() => { lockedUpdate(l, (v: Idx): Idx => ({ head: v.head + 1, tail: v.tail })); return 0; });
	await bump;
	await bump2;
	console.log(`lk=${lockedRead(l, (v: Idx): int32 => v.head)}`);
}
await main();
