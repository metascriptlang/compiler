// @stdout: async-param 12
// @stdout: async-view 2
// @stdout: generator-param 0 2
// @stdout: generator-view 0 2
// @stdout: task 12
// @stdout: async-view-replaced 2
// @stdout: generator-view-replaced 0 20
// note: a closure made in an async function or a generator may capture a parameter, or a view read from one, and run after the routine has suspended. The routine's frame outlives the call that lent the parameter, and here the caller's array is a temporary gone by then, so what the closure holds is counted. A closure called inside a spawned task, which the routine awaits before it can end, still holds its view without a count (`src/test/c/spawnCaptureCursor.ms`).

class Item { v: int32 = 0; next: Item | null = null; }

function make(): Item[] {
	const a: Item[] = [];
	for (let i: int32 = 0; i < 10; i++) {
		const it = new Item();
		it.v = i;
		a.push(it);
	}
	a[0].next = a[3];
	a[3].next = a[0];
	return a;
}

async function tick(): Promise<int32> {
	return 1;
}

async function asyncParam(xs: Item[]): Promise<int32> {
	const g = (): int32 => xs[2].v + xs.length;
	await tick();
	return g();
}

async function asyncView(xs: Item[]): Promise<int32> {
	const best = xs[2];
	const g = (): int32 => best.v;
	await tick();
	return g();
}

function* generatorParam(xs: Item[]): Iterator<int32> {
	const g = (): int32 => xs[2].v;
	yield 0;
	yield g();
}

function* generatorView(xs: Item[]): Iterator<int32> {
	const best = xs[2];
	const g = (): int32 => best.v;
	yield 0;
	yield g();
}

async function task(xs: Item[]): Promise<int32> {
	await tick();
	const t = spawn((): int32 => {
		const best = xs[2];
		const ok = (x: Readonly<Item>): boolean => x.v >= best.v;
		let n: int32 = 0;
		for (const x of xs) if (ok(x)) n += 1;
		return n;
	});
	return await t + 4;
}

function drain(g: Iterator<int32>): string {
	let out = "";
	let r = g.next();
	while (!r.done) {
		out = out + " " + String(r.value);
		r = g.next();
	}
	return out;
}

const p1 = asyncParam(make());
const p2 = asyncView(make());
const g1 = generatorParam(make());
const g2 = generatorView(make());
const p3 = task(make());
console.log("async-param " + String(await p1));
console.log("async-view " + String(await p2));
console.log("generator-param" + drain(g1));
console.log("generator-view" + drain(g2));
console.log("task " + String(await p3));

const xs: Item[] = make();
const p4 = asyncView(xs);
const r = new Item();
r.v = 99;
xs[2] = r;
console.log("async-view-replaced " + String(await p4));
const ys: Item[] = make();
for (const y of ys) y.v = y.v * 10;
const g3 = generatorView(ys);
const first = g3.next();
const q = new Item();
q.v = 77;
ys[2] = q;
const second = g3.next();
console.log("generator-view-replaced " + String(first.value) + " " + String(second.value));
