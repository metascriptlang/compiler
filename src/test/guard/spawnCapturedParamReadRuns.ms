// The legal neighbours of spawnParamRebindRejects.ms: a thunk that only reads a captured
// parameter, rebinds its own local of the same name, or rebinds the parameter after the join.
//
// GUARD-JS

class C { v: int32; constructor(v: int32) { this.v = v; } }

async function readOnly(p: C): Promise<int32> {
	const h = spawn(() => p.v * 2);
	return await h + p.v;
}

async function shadowedLocal(p: number): Promise<number> {
	const h = spawn(() => {
		let p = 10;
		p += 1;
		return p;
	});
	return await h + p;
}

async function rebindAfterJoin(p: C): Promise<int32> {
	const h = spawn(() => p.v + 1);
	const r = await h;
	p = new C(r);
	return p.v;
}

const r = await readOnly(new C(3)) + await shadowedLocal(1) + await rebindAfterJoin(new C(4));
console.log(`r=${r}`);
if (r == 26) console.log("GUARD-OK");
