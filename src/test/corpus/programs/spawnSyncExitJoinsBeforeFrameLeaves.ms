// @stdout: ok=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS has no pool, so no waiter reads another task's frame
// note: a synchronous body spawns joined children and leaves before awaiting them by a throw, a callee's throw, an early return and a break, while a slot tree's waiters search the queue through the ancestors of each queued task. Every exit joins the children before the body's frame leaves (T2), so no queued task names a frame that is gone (SAN lane: no stack-use-after-return).
function work(n: int32): int32 {
	let x: int32 = 0;
	for (let i: int32 = 0; i < n; i++) x = (x * 31 + i) % 1000003;
	return x % 2 + 1;
}

function fail(): void {
	throw new Error("callee");
}

// Joined children left behind by every early exit of a synchronous body.
function leave(k: int32): int32 {
	const a = spawn(() => work(200000));
	const b = spawn(() => work(200000));
	if (k == 0) throw new Error("throw");
	if (k == 1) fail();
	if (k == 2) return 7;
	let joined: int32 = 0;
	for (let i = 0; i < 3; i++) {
		const c = spawn(() => work(200000));
		if (i == 1) break;
		joined = joined + await c;
	}
	return await a + await b + joined;
}

function task(k: int32): int32 {
	try {
		return leave(k);
	} catch (e) {
		return 1;
	}
}

function tree(d: int32): int32 {
	if (d == 0) return work(20000);
	const a = spawn(() => tree(d - 1));
	const b = spawn(() => tree(d - 1));
	return await a + await b;
}

let s: int32 = 0;
for (let round = 0; round < 20; round++) {
	const hs: Promise<int32>[] = [];
	for (let i = 0; i < 32; i++) {
		const k = i % 4;
		hs.push(spawn(() => task(k)));
	}
	const t = spawn(() => tree(8));
	for (const h of hs) s += await h;
	s += await t;
}
console.log(`ok=${s > 0}`);
