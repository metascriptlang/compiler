// @stdout: total=44000
// @skip-js: syncByName awaits in a sync function, and JS has no blocking wait
// note: a task that runs a named closure, by name or from inside its thunk, shares that closure's env with the parent, which drops its own closure while the task runs or right after the await. The task reads the env through the parent's reference and counts nothing on it, so the env's count is only ever touched on the parent's thread.

class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder { child: Child; constructor(c: Child) { this.child = c; } }

async function byName(): Promise<int32> {
	const ring = new Holder(new Child(1));
	const cut = (): int32 => ring.child.v + 1;
	const r = await spawn(cut);
	ring.child = new Child(r);
	return ring.child.v;
}

async function calledFromThunk(): Promise<int32> {
	const ring = new Holder(new Child(2));
	const cut = (): int32 => ring.child.v + 1;
	const r = await spawn((): int32 => cut() + cut());
	ring.child = new Child(r);
	return ring.child.v;
}

async function calledOneLevelDeeper(): Promise<int32> {
	const ring = new Holder(new Child(3));
	const cut = (): int32 => ring.child.v;
	const r = await spawn((): int32 => {
		const inner = (): int32 => cut() * 2;
		return inner();
	});
	ring.child = new Child(r);
	return ring.child.v;
}

function syncByName(): int32 {
	const ring = new Holder(new Child(4));
	const view = ring;
	const cut = (): int32 => { const again = view; return again.child.v + 4; };
	const r = await spawn(cut);
	ring.child = new Child(r);
	return ring.child.v;
}

let total: int32 = 0;
for (let i = 0; i < 2000; i++) total += await byName() + await calledFromThunk() + await calledOneLevelDeeper() + syncByName();
console.log(`total=${total}`);
