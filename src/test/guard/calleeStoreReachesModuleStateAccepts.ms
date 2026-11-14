// The legal neighbours of calleeStoreReachesModuleStateRefused.ms: a callee that only reads module
// state, or only compares its argument against it; a callee that stores a value built there while it
// reads a module scalar; a callee that ties another value to module state, not the lent one; a callee
// that stores after the await; a recursive callee that only reads; a closure handed to a callee that
// ties nothing to module state; a callee that reads one argument while it stores into the other; a
// closure bound by const whose result is its argument's field, called in a task on a lent value; a
// routine that returns, through an alias, a value built from a module scalar; a class whose field
// initializer reads a module scalar.
//
// INVARIANT (ULTRALOCK V0, V4): a callee whose body is visible ties to module state only the inputs
//   its body stores, so a value it only reads stays lendable.
//
// RED MEANS: the module-state reach check refuses a value that cannot race.
//
// GUARD-JS

class Node { v: int32 = 1; child: Node | null = null; }
class Leaf { v: int32 = 1; }
const SHARED = new Node();
const REGISTRY: Node[] = [];
let COUNTER: int32 = 3;
class Counted { items: Node[] = []; v: int32 = COUNTER; }

function fill(out: Node[]): void { out.push(SHARED); }
function register(n: Node): void { REGISTRY.push(n); }
function onlyReads(out: Node[]): int32 { return SHARED.v + out.length; }
function compares(out: Node[]): boolean { return out.length > 0 && out[0] === SHARED; }
function addFresh(out: Node[]): void {
	const n = new Node();
	n.v = COUNTER;
	out.push(n);
}
function total(n: Node): int32 { return n.v + (n.child != null ? total(n.child!) : 0); }
function each(out: Node[], f: (n: Node) => void): void { for (const n of out) { f(n); } }
function countInto(seen: int32[], from: Leaf[]): void { seen.push(from.length); }
function freshReturn(): Node[] { const a: Node[] = []; const b = a; const n = new Node(); n.v = COUNTER; b.push(n); return a; }

async function readerOk(): Promise<int32> {
	const out: Node[] = [new Node()];
	const n = onlyReads(out);
	return n + await spawn(() => out[0].v);
}

async function comparerOk(): Promise<int32> {
	const out: Node[] = [new Node()];
	const same = compares(out);
	return (same ? 1 : 0) + await spawn(() => out[0].v);
}

async function freshStoreOk(): Promise<int32> {
	const out: Node[] = [];
	addFresh(out);
	return await spawn(() => out[0].v);
}

async function otherValueOk(): Promise<int32> {
	const tied: Node[] = [];
	const free: Node[] = [new Node()];
	fill(tied);
	register(new Node());
	return tied.length + await spawn(() => free[0].v);
}

async function afterJoinOk(): Promise<int32> {
	const out: Node[] = [new Node()];
	const t = await spawn(() => out[0].v);
	fill(out);
	return t + out.length;
}

async function recursiveReaderOk(): Promise<int32> {
	const root = new Node();
	root.child = new Node();
	const sum = total(root);
	return sum + await spawn(() => root.v);
}

async function passedClosureOk(): Promise<int32> {
	const out: Node[] = [new Node()];
	let sum: int32 = 0;
	each(out, (n: Node): void => { sum += n.v; });
	return sum + await spawn(() => out[0].v);
}

async function readsOneStoresOtherOk(): Promise<int32> {
	const from: Leaf[] = [new Leaf()];
	const seen: int32[] = [];
	countInto(seen, from);
	const t = spawn(() => from[0].v);
	seen.push(7);
	return seen.length + await t;
}

async function boundReaderInTaskOk(): Promise<int32> {
	const g = new Node();
	g.child = new Node();
	const t = spawn(() => {
		const pick = (x: Readonly<Node>) => x.child;
		const c = pick(g);
		return c != null ? c.v : 0;
	});
	return await t;
}

async function freshReturnOk(): Promise<int32> {
	const b = freshReturn();
	return await spawn(() => b[0].v);
}

async function scalarInitializerOk(): Promise<int32> {
	const c = new Counted();
	return await spawn(() => c.v);
}

async function main(): Promise<void> {
	const a = await readerOk() + await comparerOk() + await freshStoreOk() + await otherValueOk();
	const b = await afterJoinOk() + await recursiveReaderOk() + await passedClosureOk() + await readsOneStoresOtherOk() + await boundReaderInTaskOk() + await freshReturnOk() + await scalarInitializerOk();
	console.log(`a=${a} b=${b}`);
	if (a == 9 && b == 18) console.log("GUARD-OK");
}

await main();
