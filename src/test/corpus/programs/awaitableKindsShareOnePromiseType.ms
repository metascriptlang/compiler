// @stdout: async 2
// @stdout: call 3
// @stdout: all 10
// @stdout: spawn 2
// @stdout: sum 17
// @ledger-slack(Other) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// An async call, an actor CALL, Promise.all and a spawn all type as Promise<T>:
// each binds to an annotated Promise and is awaited through one async helper.

function work(n: int32): int32 { return n + 1; }

async function asy(n: int32): Promise<int32> { return n * 2; }

actor Other { get(n: int32): int32 { return n * 3; } }

async function settle(label: string, p: Promise<int32>): Promise<int32> {
	const v = await p;
	console.log(`${label} ${v}`);
	return v;
}

async function run(): Promise<int32> {
	const o = new Other();
	const a: Promise<int32> = asy(1);
	const b: Promise<int32> = o.get(1);
	const c: Promise<int32[]> = Promise.all([asy(2), asy(3)]);
	const d: Promise<int32> = spawn(() => work(1));
	const va = await settle("async", a);
	const vb = await settle("call", b);
	const cs = await c;
	console.log(`all ${cs[0] + cs[1]}`);
	const vd = await d;
	console.log(`spawn ${vd}`);
	return va + vb + cs[0] + cs[1] + vd;
}

console.log(`sum ${await run()}`);
