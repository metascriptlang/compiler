// The legal neighbours of actorCallLendRefuses.ms: an awaited actor CALL's borrowed argument is
// read while the call is pending, handed to a callee that takes it as Readonly, lent to two calls
// joined by one Promise.all, and changed only after the await that consumes the reply; a string or
// a scalar argument is a copy, so the caller may change its own binding while the call is pending.
//
// INVARIANT (ULTRALOCK V6, V4, V1): reads stay legal inside the lend window, the window closes at
//   the consuming await, and a value copied at the crossing lends nothing.
//
// RED MEANS: the lend window refuses a read, outlives its await, or treats a copied argument as lent.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

class Box { v: int32 = 1; }

actor Reader {
	watch(a: int32[]): int32 { return a[0] * 10 + a.length; }
	see(b: Box): int32 { return b.v; }
	text(s: string): int32 { return s.length; }
	num(n: int32): int32 { return n; }
}

function peek(a: Readonly<int32[]>): int32 { return a[0]; }

async function awaitFirst(r: Reader): Promise<int32> {
	const arr: int32[] = [1, 2];
	const v = await r.watch(arr);
	arr[0] = 42;
	arr.push(3);
	return v + arr[0] - 42;
}

async function readBeforeAwait(r: Reader): Promise<int32> {
	const arr: int32[] = [2, 2];
	const p = r.watch(arr);
	const seen = arr[0] + arr.length + peek(arr);
	const v = await p;
	arr[0] = v + seen;
	return arr[0];
}

async function boxAfterAwait(r: Reader): Promise<int32> {
	const b = new Box();
	const p = r.see(b);
	const v = await p;
	b.v = v + 1;
	return b.v;
}

async function twoReaders(r: Reader): Promise<int32> {
	const arr: int32[] = [3];
	const rs = await Promise.all([r.watch(arr), r.watch(arr)]);
	arr[0] = rs[0] + rs[1];
	return arr[0];
}

async function copies(r: Reader): Promise<int32> {
	let s = "abc";
	let n: int32 = 4;
	const ps = r.text(s);
	const pn = r.num(n);
	s = "changed";
	n = 9;
	return await ps + await pn + n - 9 + s.length - 7;
}

async function main(): Promise<void> {
	const r = new Reader();
	const a = await awaitFirst(r);
	const b = await readBeforeAwait(r);
	const c = await boxAfterAwait(r);
	const d = await twoReaders(r);
	const e = await copies(r);
	stop(r.pid, ExitReason.Normal);
	console.log(`a=${a} b=${b} c=${c} d=${d} e=${e}`);
	if (a == 12 && b == 28 && c == 2 && d == 62 && e == 7) console.log("GUARD-OK");
}

await main();
