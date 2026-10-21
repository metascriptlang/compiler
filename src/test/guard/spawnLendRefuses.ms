// A spawn lends what its thunk reads until the await that joins it; the parent may read it in
// that span but not change it, directly, through an alias, a callee or a closure. Each case below
// changes the lent value while the task still reads it, and each must be a compile error that names
// the spawn. The legal neighbours (a read in the span, a change after the join) are pinned by
// spawnLendAccepts.ms, which must build and run.
//
// GUARD-CHECK-FAIL 'fieldObj' is lent to the spawn
// GUARD-CHECK-FAIL 'elemArr' is lent to the spawn
// GUARD-CHECK-FAIL 'lenArr' is lent to the spawn
// GUARD-CHECK-FAIL 'aliasObj' is lent to the spawn
// GUARD-CHECK-FAIL 'loopH' is lent to the spawn
// GUARD-CHECK-FAIL 'calleeObj' is lent to the spawn
// GUARD-CHECK-FAIL 'closureObj' is lent to the spawn
// GUARD-CHECK-FAIL 'asyncObj' is lent to the spawn
// GUARD-CHECK-FAIL 'branchObj' is lent to the spawn
// GUARD-CHECK-FAIL 'manyObj' is lent to the spawn
// GUARD-CHECK-FAIL 'primN' is lent to the spawn
// GUARD-CHECK-FAIL 'methodObj' is lent to the spawn
// GUARD-CHECK-FAIL 'this' is lent to the spawn
// GUARD-CHECK-FAIL 'moduleObj' is lent to the spawn
import { stop, ExitReason } from "std/actor";

class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder {
	child: Child;
	constructor(c: Child) { this.child = c; }
	replace(v: int32): void { this.child = new Child(v); }
}

function poke(h: Holder, i: int32): void { h.child = new Child(i); }

function field(): int32 {
	const fieldObj = new Holder(new Child(1));
	const f = spawn(() => fieldObj.child.v);
	fieldObj.child = new Child(2);
	return await f;
}

function elem(): int32 {
	const elemArr: Child[] = [new Child(1), new Child(2)];
	const f = spawn(() => elemArr[1].v);
	elemArr[1] = new Child(3);
	return await f;
}

function len(): int32 {
	const lenArr: Child[] = [new Child(1)];
	const f = spawn(() => lenArr.length > 0 ? lenArr[0].v : 0);
	lenArr.length = 0;
	return await f;
}

function alias(): int32 {
	const aliasObj = new Holder(new Child(1));
	const other = aliasObj;
	const f = spawn(() => aliasObj.child.v);
	other.child = new Child(2);
	return await f;
}

function loopBinding(hs: Holder[]): int32 {
	let t: int32 = 0;
	for (const loopH of hs) {
		const f = spawn(() => loopH.child.v);
		loopH.child = new Child(2);
		t = t + await f;
	}
	return t;
}

function callee(): int32 {
	const calleeObj = new Holder(new Child(1));
	const f = spawn(() => calleeObj.child.v);
	poke(calleeObj, 2);
	return await f;
}

function method(): int32 {
	const methodObj = new Holder(new Child(1));
	const f = spawn(() => methodObj.child.v);
	methodObj.replace(2);
	return await f;
}

function closure(): int32 {
	const closureObj = new Holder(new Child(1));
	const bump = (i: int32): void => { closureObj.child = new Child(i); };
	const f = spawn(() => closureObj.child.v);
	bump(2);
	return await f;
}

async function asyncParent(): Promise<int32> {
	const asyncObj = new Holder(new Child(1));
	const f = spawn(() => asyncObj.child.v);
	asyncObj.child = new Child(2);
	return await f;
}

function branchSkipsAwait(c: boolean): int32 {
	const branchObj = new Holder(new Child(1));
	const f = spawn(() => branchObj.child.v);
	let r: int32 = 0;
	if (c) r = await f;
	branchObj.child = new Child(2);
	return r;
}

function spawnInLoop(): int32 {
	const manyObj = new Holder(new Child(1));
	const fs: Promise<int32>[] = [];
	for (let k = 0; k < 2; k += 1) fs.push(spawn(() => manyObj.child.v));
	manyObj.child = new Child(2);
	let t: int32 = 0;
	for (const f of fs) t = t + await f;
	return t;
}

function primitiveParam(primN: int32): int32 {
	const f = spawn(() => primN * 2);
	primN = 5;
	return await f + primN;
}

actor Lender {
	obj: Holder;
	constructor() { this.obj = new Holder(new Child(1)); }
	go(): int32 {
		const f = spawn(() => this.obj.child.v);
		this.obj.child = new Child(2);
		return await f;
	}
}

const moduleObj = new Holder(new Child(1));
const g = spawn(() => moduleObj.child.v);
moduleObj.child = new Child(2);

async function main(): Promise<void> {
	const a = new Lender();
	const r = field() + elem() + len() + alias() + loopBinding([new Holder(new Child(1))]) + callee() + method() + closure()
		+ await asyncParent() + branchSkipsAwait(true) + spawnInLoop() + primitiveParam(1) + await a.go() + await g;
	console.log(`r=${r}`);
	stop(a.pid, ExitReason.Normal);
}
main();
