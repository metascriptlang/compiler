// The legal neighbours of spawnLendAsyncCalleeRefuses.ms: the caller changes what it passed to an
// async callee only after awaiting the callee's promise, or the callee's spawn copies what it reads
// so the task borrows nothing, or the callee spawns nothing and the change is an ordinary
// interleaving on the caller's own thread, also when that callee is passed as a function value.
// A callee that throws before awaiting the promise it holds joins it at its exit, so its caller
// changes the object only after the task is done: TSan sees no race there. Each must build, run,
// and read the value it lent.
//
// GUARD-JS
// GUARD-TSAN

class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder {
	child: Child;
	constructor(c: Child) { this.child = c; }
	async sum(): Promise<int32> {
		const f = spawn(() => this.child.v * 10);
		return await f;
	}
}

async function worker(h: Holder): Promise<int32> {
	const f = spawn(() => {
		let s: int32 = 0;
		for (let i = 0; i < 1000; i += 1) s += h.child.v;
		return s;
	});
	await new Promise<void>((res: () => void): void => { setTimeout(res, 1); });
	return await f;
}

async function copier(h: Holder): Promise<int32> {
	const n = h.child.v;
	const f = spawn(() => n * 1000);
	return await f;
}

async function noSpawn(h: Holder): Promise<int32> {
	await new Promise<void>((res: () => void): void => { setTimeout(res, 1); });
	return h.child.v;
}

async function awaitHandleFirst(): Promise<int32> {
	const obj = new Holder(new Child(3));
	const p = worker(obj);
	const seen = obj.child.v;
	const r = await p;
	obj.child = new Child(7);
	return r + seen;
}

async function awaitCallDirectly(): Promise<int32> {
	const obj = new Holder(new Child(2));
	const r = await worker(obj);
	obj.child = new Child(9);
	return r;
}

async function methodAwaitedFirst(): Promise<int32> {
	const obj = new Holder(new Child(4));
	const p = obj.sum();
	const r = await p;
	obj.child = new Child(5);
	return r;
}

async function isolatedCallee(): Promise<int32> {
	const obj = new Holder(new Child(1));
	const p = copier(obj);
	obj.child = new Child(8);
	return await p;
}

async function sameThreadCallee(): Promise<int32> {
	const obj = new Holder(new Child(1));
	const p = noSpawn(obj);
	obj.child = new Child(6);
	return await p;
}

async function joinBoth(): Promise<int32> {
	const obj = new Holder(new Child(1));
	const rs = await Promise.all([obj.sum(), obj.sum()]);
	obj.child = new Child(rs[0] + rs[1]);
	return obj.child.v;
}

async function run(f: (h: Holder) => Promise<int32>, h: Holder): Promise<int32> { return await f(h); }

async function neverSpawnsAsValue(): Promise<int32> {
	const obj = new Holder(new Child(1));
	const p = run(noSpawn, obj);
	obj.child = new Child(4);
	return await p;
}

async function throwsBeforeAwait(h: Holder, fail: boolean): Promise<int32> {
	const p = worker(h);
	if (fail) throw new Error("before the await");
	return await p;
}

async function changeAfterThrow(): Promise<int32> {
	const obj = new Holder(new Child(5));
	try {
		await throwsBeforeAwait(obj, true);
	} catch (e) {
		obj.child = new Child(1);
	}
	return obj.child.v;
}

const r = await awaitHandleFirst() + await awaitCallDirectly() + await methodAwaitedFirst() + await isolatedCallee()
	+ await sameThreadCallee() + await joinBoth() + await neverSpawnsAsValue() + await changeAfterThrow();
if (r == 3003 + 2000 + 40 + 1000 + 6 + 20 + 4 + 1) console.log("GUARD-OK");
else console.log(`unexpected r=${r}`);
