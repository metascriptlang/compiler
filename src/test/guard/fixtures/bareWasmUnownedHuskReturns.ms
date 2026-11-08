let destroyed: int32 = 0;

class N {
	a: int64 = 0;
	b: int64 = 0;
	c: int64 = 0;
	d: int64 = 0;
	e: int64 = 0;
	f: int64 = 0;
	g: int64 = 0;
	h: int64 = 0;
}

function onDestroy(this n: N): void {
	destroyed += 1;
}

class H { at: Unowned<N> | null = null; }

function attach(h: H): void {
	const n = new N();
	h.at = n;
}

function round(i: int32): void {
	const h = new H();
	attach(h);
	if (i % 2 == 0) h.at = null;
}

for (let i: int32 = 0; i < 16384; i++) round(i);
if (destroyed != 16384) throw new Error(`bare Wasm destroyed ${destroyed} of 16384 Unowned targets`);
