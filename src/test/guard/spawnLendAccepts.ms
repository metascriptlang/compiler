// The legal neighbours of spawnLendRefuses.ms: a lent value is read while the task runs, handed to
// a callee that takes it as Readonly, and changed only after the await that joins the task.
//
// GUARD-JS

class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder { child: Child; total: int32 = 0; constructor(c: Child) { this.child = c; } }

function peek(h: Readonly<Holder>): int32 { return h.child.v; }

async function readInWindow(): Promise<int32> {
	const obj = new Holder(new Child(3));
	const f = spawn(() => obj.child.v);
	const seen = obj.child.v + peek(obj);
	const r = await f;
	obj.child = new Child(r + seen);
	return obj.child.v;
}

async function assignAfterJoin(): Promise<int32> {
	const obj = new Holder(new Child(4));
	const f = spawn(() => obj.child.v * 2);
	obj.total = await f;
	return obj.total;
}

async function joinAll(): Promise<int32> {
	const obj = new Holder(new Child(1));
	const rs = await Promise.all([spawn(() => obj.child.v), spawn(() => obj.child.v + 1)]);
	obj.child = new Child(rs[0] + rs[1]);
	return obj.child.v;
}

async function thunkOwnArray(): Promise<int32> {
	const obj = new Holder(new Child(2));
	const f = spawn(() => {
		const xs: int32[] = [];
		for (let i = 0; i < 3; i += 1) xs.push(obj.child.v);
		return xs.length;
	});
	console.log("waiting");
	const n = await f;
	obj.child = new Child(n);
	return obj.child.v;
}

async function eachIteration(hs: Holder[]): Promise<int32> {
	let t: int32 = 0;
	for (const h of hs) {
		const f = spawn(() => h.child.v);
		t = t + await f;
		h.child = new Child(t);
	}
	return t;
}

const r = await readInWindow() + await assignAfterJoin() + await joinAll() + await thunkOwnArray()
	+ await eachIteration([new Holder(new Child(1)), new Holder(new Child(2))]);
if (r == 26) console.log("GUARD-OK");
else console.log(`unexpected r=${r}`);
