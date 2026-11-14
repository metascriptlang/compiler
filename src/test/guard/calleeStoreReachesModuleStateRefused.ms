// A value a callee ties to module state is refused where it is lent to a task, whichever way the
// callee ties it: by storing module state into its parameter, its receiver or a local it captured,
// or by storing that input into module state, in a function or a constructor.
//
// INVARIANT (ULTRALOCK V0, V4): a partition reachable from module state is not lendable, directly
//   or through a callee. A call joins the inputs its callee stores into one another, and an input
//   the callee ties to module state joins the module's region at the call. A callee the checker
//   cannot see counts as reaching module state.
//
// WHAT IT CATCHES: the state measured 2026-11-14 on bac1b95e1948, where every function below passed
//   `msc check` and only the same store written in the lending function itself was refused.
//
// RED MEANS: main writes the module object while a task on another thread reads it through the
//   lent local.
//
// The legal neighbours are pinned by calleeStoreReachesModuleStateAccepts.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL is lent to the spawn
// GUARD-CHECK-FAIL calls 'fill'
// GUARD-CHECK-FAIL calls 'register'
// GUARD-CHECK-FAIL is captured by 'add'
// GUARD-CHECK-FAIL as overridden in 'SharedFiller'
// GUARD-CHECK-FAIL a function value, which may tie it to module state
// GUARD-CHECK-FAIL uses module-level 'SHARED'
// GUARD-CHECK-FAIL uses module-level 'REGISTRY'
// GUARD-CHECK-FAIL uses module-level 'CURRENT'
// GUARD-CHECK-FAIL constructs 'Keeper'
// GUARD-CHECK-FAIL calls 'pick'
// GUARD-CHECK-FAIL module state crosses threads only as a const value

class Node { v: int32 = 1; child: Node | null = null; }
class Holder { one: Node = new Node(); }
class Leaf { v: int32 = 1; }
const SHARED = new Node();
const SHARED_LEAF = new Leaf();
const REGISTRY: Node[] = [];
let CURRENT: Node | null = null;

class Bag {
	items: Node[] = [];
	fill(): void { this.items.push(SHARED); }
	replace(): void { this.items = [SHARED]; }
}
class Filler { fill(out: Node[]): void { } }
class SharedFiller extends Filler { fill(out: Node[]): void { out.push(SHARED); } }

function pick(): Node { return SHARED; }
function fill(out: Node[]): void { out.push(SHARED); }
function fillDeep(out: Node[]): void { fill(out); }
function fillAlias(out: Node[]): void { const o = out; o.push(SHARED); }
function fillIndex(out: Node[]): void { out[0] = SHARED; }
function fillField(h: Holder): void { h.one = SHARED; }
function fillLocalFirst(out: Node[]): void { const s = SHARED; out.push(s); }
function fillFromCall(out: Node[]): void { out.push(pick()); }
function fillElement(out: Node[]): void { for (const n of out) { n.child = SHARED; } }
function fillBag(b: Bag): void { b.items.push(SHARED); }
function fillAfter(out: Node[], k: int32): void {
	if (k == 0) {
		out.push(SHARED);
		return;
	}
	fillAfter(out, k - 1);
}
function copyInto(out: Leaf[], src: Leaf[]): void { out.push(src[0]); }
function register(n: Node): void { REGISTRY.push(n); }
function registerDeep(n: Node): void { register(n); }
function registerAlias(n: Node): void { const r = REGISTRY; r.push(n); }
function hang(n: Node): void { SHARED.child = n; }
function setCurrent(n: Node): void { CURRENT = n; }
class Keeper { constructor(n: Node) { REGISTRY.push(n); } }
function each(out: Node[], f: (n: Node) => void): void { for (const n of out) { f(n); } }

async function viaParam(): Promise<int32> {
	const out: Node[] = [];
	fill(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaThis(): Promise<int32> {
	const b = new Bag();
	b.fill();
	return await spawn(() => b.items[0].v); // GUARD-REFUSED
}

async function viaThisField(): Promise<int32> {
	const b = new Bag();
	b.replace();
	return await spawn(() => b.items[0].v); // GUARD-REFUSED
}

async function viaDeep(): Promise<int32> {
	const out: Node[] = [];
	fillDeep(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaClosure(): Promise<int32> {
	const kept: Node[] = [];
	const add = (): void => { kept.push(SHARED); };
	add();
	return await spawn(() => kept[0].v); // GUARD-REFUSED
}

async function viaClosureOfClosure(): Promise<int32> {
	const kept: Node[] = [];
	const add = (): void => { kept.push(SHARED); };
	const twice = (): void => { add(); add(); };
	twice();
	return await spawn(() => kept[0].v); // GUARD-REFUSED
}

async function viaAlias(): Promise<int32> {
	const out: Node[] = [];
	fillAlias(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaIndex(): Promise<int32> {
	const out: Node[] = [new Node()];
	fillIndex(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaField(): Promise<int32> {
	const h = new Holder();
	fillField(h);
	return await spawn(() => h.one.v); // GUARD-REFUSED
}

async function viaLocalFirst(): Promise<int32> {
	const out: Node[] = [];
	fillLocalFirst(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaCallResult(): Promise<int32> {
	const out: Node[] = [];
	fillFromCall(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaElement(): Promise<int32> {
	const out: Node[] = [new Node()];
	fillElement(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaNestedField(): Promise<int32> {
	const b = new Bag();
	fillBag(b);
	return await spawn(() => b.items[0].v); // GUARD-REFUSED
}

async function viaRecursion(): Promise<int32> {
	const out: Node[] = [];
	fillAfter(out, 3);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaOverride(f: Filler): Promise<int32> {
	const out: Node[] = [];
	f.fill(out);
	return await spawn(() => out.length); // GUARD-REFUSED
}

async function viaOtherArgument(): Promise<int32> {
	const out: Leaf[] = [];
	const src: Leaf[] = [SHARED_LEAF];
	copyInto(out, src);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaBoundClosureParameter(): Promise<int32> {
	const out: Node[] = [];
	const f = (o: Node[]): void => { o.push(SHARED); };
	f(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaFunctionValue(f: (o: Node[]) => void): Promise<int32> {
	const out: Node[] = [];
	f(out);
	return await spawn(() => out.length); // GUARD-REFUSED
}

async function viaPassedClosure(): Promise<int32> {
	const out: Node[] = [new Node()];
	each(out, (n: Node): void => { n.child = SHARED; });
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function viaPassedFunctionValue(f: (n: Node) => void): Promise<int32> {
	const out: Node[] = [new Node()];
	each(out, f);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function storedByCallee(): Promise<int32> {
	const n = new Node();
	register(n);
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function storedByCalleeDeep(): Promise<int32> {
	const n = new Node();
	registerDeep(n);
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function storedThroughAlias(): Promise<int32> {
	const n = new Node();
	registerAlias(n);
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function elementStoredByCallee(): Promise<int32> {
	const out: Node[] = [new Node()];
	register(out[0]);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function hungByCallee(): Promise<int32> {
	const n = new Node();
	hang(n);
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function hungHere(): Promise<int32> {
	const n = new Node();
	SHARED.child = n;
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function keptByModuleLet(): Promise<int32> {
	const n = new Node();
	CURRENT = n;
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function keptByCalleeLet(): Promise<int32> {
	const n = new Node();
	setCurrent(n);
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function keptByConstructor(): Promise<int32> {
	const n = new Node();
	const k = new Keeper(n);
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function boundClosureResult(): Promise<int32> {
	const out: Node[] = [];
	const pick = (): Node => SHARED;
	out.push(pick());
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function main(): Promise<void> {
	console.log(await viaParam() + await viaThis() + await viaThisField() + await viaDeep() + await viaClosure() + await viaClosureOfClosure());
	console.log(await viaAlias() + await viaIndex() + await viaField() + await viaLocalFirst() + await viaCallResult() + await viaElement());
	console.log(await viaNestedField() + await viaRecursion() + await viaOverride(new SharedFiller()) + await viaOtherArgument());
	console.log(await viaBoundClosureParameter() + await viaFunctionValue(fill) + await viaPassedClosure() + await viaPassedFunctionValue(register));
	console.log(await storedByCallee() + await storedByCalleeDeep() + await storedThroughAlias() + await elementStoredByCallee() + await hungByCallee() + await hungHere());
	console.log(await keptByModuleLet() + await keptByCalleeLet() + await keptByConstructor() + await boundClosureResult());
}

await main();
