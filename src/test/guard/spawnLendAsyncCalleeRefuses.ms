// An async routine runs until its first suspension and hands its caller a promise; a spawn it
// starts over a parameter, or over anything reachable from one, keeps reading that parameter on
// another thread after the call has returned. So the call lends what it passes for that parameter
// until the caller awaits the call's promise, as an inline spawn lends what its thunk reads until
// its await: the caller may read it in that span but not change it, directly or through a callee,
// and the promise stays in the scope that made the call, as a borrowing spawn's handle does. A call
// through a function value cannot hold what the caller lends, so such a routine does not become one.
// Each case below breaks that and must be a compile error. The legal neighbours (the caller awaits
// first, the callee's spawn is isolated, the callee spawns nothing, a routine that never spawns
// passed as a value) are pinned by spawnLendAsyncCalleeAccepts.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL 'writeObj' is lent to the spawn
// GUARD-CHECK-FAIL 'methodObj' is lent to the spawn
// GUARD-CHECK-FAIL 'calleeObj' is lent to the spawn
// GUARD-CHECK-FAIL 'deepObj' is lent to the spawn
// GUARD-CHECK-FAIL 'passObj' is lent to the spawn
// GUARD-CHECK-FAIL 'syncObj' is lent to the spawn
// GUARD-CHECK-FAIL 'discardObj' is lent to the spawn
// GUARD-CHECK-FAIL returning it
// GUARD-CHECK-FAIL storing it in 'box.p'
// GUARD-CHECK-FAIL passing it to 'keep'
// GUARD-CHECK-FAIL 'worker' cannot become a function value
// GUARD-CHECK-FAIL this async function value cannot be made

class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder {
	child: Child;
	constructor(c: Child) { this.child = c; }
	async sum(): Promise<int32> {
		const f = spawn(() => this.child.v);
		return await f;
	}
}
class Box { p: Promise<int32> | null = null; }

async function worker(h: Holder): Promise<int32> {
	const f = spawn(() => h.child.v);
	return await f;
}

async function inner(h: Holder): Promise<int32> {
	const f = spawn(() => h.child.v);
	return await f;
}

async function outer(h: Holder): Promise<int32> { return await inner(h); }

async function passOn(h: Holder): Promise<int32> {
	const p = worker(h);
	return await p;
}

function replace(h: Holder, v: int32): void { h.child = new Child(v); }
function keep(p: Promise<int32>): void {}

async function writeBeforeAwait(): Promise<int32> {
	const writeObj = new Holder(new Child(1));
	const p = worker(writeObj); // GUARD-REFUSED
	writeObj.child = new Child(2);
	return await p;
}

async function methodLendsThis(): Promise<int32> {
	const methodObj = new Holder(new Child(1));
	const p = methodObj.sum(); // GUARD-REFUSED
	methodObj.child = new Child(2);
	return await p;
}

async function writeThroughCallee(): Promise<int32> {
	const calleeObj = new Holder(new Child(1));
	const p = worker(calleeObj); // GUARD-REFUSED
	replace(calleeObj, 2);
	return await p;
}

async function lendOneCallDeeper(): Promise<int32> {
	const deepObj = new Holder(new Child(1));
	const p = outer(deepObj); // GUARD-REFUSED
	deepObj.child = new Child(2);
	return await p;
}

async function lendThroughParameter(): Promise<int32> {
	const passObj = new Holder(new Child(1));
	const p = passOn(passObj); // GUARD-REFUSED
	passObj.child = new Child(2);
	return await p;
}

async function discarded(): Promise<int32> {
	const discardObj = new Holder(new Child(1));
	worker(discardObj); // GUARD-REFUSED
	discardObj.child = new Child(2);
	return discardObj.child.v;
}

function returned(retObj: Holder): Promise<int32> {
	return worker(retObj); // GUARD-REFUSED
}

async function stored(): Promise<int32> {
	const box = new Box();
	const storeObj = new Holder(new Child(1));
	box.p = worker(storeObj); // GUARD-REFUSED
	return await box.p!;
}

async function passed(): Promise<int32> {
	const argObj = new Holder(new Child(1));
	keep(worker(argObj)); // GUARD-REFUSED
	return argObj.child.v;
}

async function run(f: (h: Holder) => Promise<int32>, h: Holder): Promise<int32> { return await f(h); }

async function passedAsValue(): Promise<int32> {
	const valueObj = new Holder(new Child(1));
	const p = run(worker, valueObj); // GUARD-REFUSED
	valueObj.child = new Child(2);
	return await p;
}

async function mapped(): Promise<int32> {
	const items = [new Holder(new Child(1)), new Holder(new Child(2))];
	const ps = items.map(worker); // GUARD-REFUSED
	items[0].child = new Child(3);
	const rs = await Promise.all(ps);
	return rs[0] + rs[1];
}

async function closureLendsCapture(): Promise<int32> {
	const capObj = new Holder(new Child(1));
	const go = async (): Promise<int32> => { // GUARD-REFUSED
		const f = spawn(() => capObj.child.v);
		return await f;
	};
	const p = go();
	capObj.child = new Child(2);
	return await p;
}

const syncObj = new Holder(new Child(1));
const sp = worker(syncObj); // GUARD-REFUSED
syncObj.child = new Child(2);

const r = await writeBeforeAwait() + await methodLendsThis() + await writeThroughCallee() + await lendOneCallDeeper()
	+ await lendThroughParameter() + await sp + await discarded() + await returned(new Holder(new Child(1)))
	+ await stored() + await passed() + await passedAsValue() + await mapped() + await closureLendsCapture();
console.log(`r=${r}`);
