// @stdout: 9 9 9 9 9
// @exit: 0
// note: an argument bound to a ref parameter, followed by an argument that awaits, stays the place it names, so the callee's write reaches it: a class field, an array element, a class-typed field, a local, and the index of the element computed before the await.

class Leaf {
	n: number;
	constructor(n: number) {
		this.n = n;
	}
}

class H {
	v: number = 1;
	xs: number[] = [1, 2, 3];
	leaf: Leaf = new Leaf(1);
}

function put(ref slot: number, x: number): void {
	slot = x;
}

function putLeaf(ref slot: Leaf, x: Leaf): void {
	slot = x;
}

async function nine(): Promise<number> {
	return 9;
}

async function run(): Promise<void> {
	const h = new H();
	put(h.v, await nine());
	put(h.xs[1], await nine());
	putLeaf(h.leaf, new Leaf(await nine()));
	let k: number = 1;
	put(k, await nine());
	let at: int32 = 0;
	put(h.xs[at], await nine());
	console.log(h.v, h.xs[1], h.leaf.n, k, h.xs[0]);
}

await run();
