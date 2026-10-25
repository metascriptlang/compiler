// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native sync-context await
// @xfail(raiser): raiser runtime error: Unknown host function: msSpawn
// @serial
// @stdout: pair caught second destroyed=20
// @stdout: middle caught middle destroyed=40
// @stdout: boxed caught boxed destroyed=40
// @stdout: async caught async destroyed=20
// note: when one child of `await Promise.all([spawn(...), ...])` fails, the results of the children that succeeded are destroyed with the awaiting scope, on the sync and the async join and for a ref and a boxed struct result (old compiler: destroyed=0, the results stayed in the group's slots and leaked). A result may be destroyed on the worker or the awaiting thread, so the hook counts through a Locked cell.

struct Count { n: int32; }

const dead: Locked<Count> = new Locked({ n: 0 });

function deadCount(): int32 {
	return lockedRead(dead, (c: Count): int32 => { return c.n; });
}

function resetDead(): void {
	lockedUpdate(dead, (c: Count): Count => { return { n: 0 }; });
}

class Obj {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

function onDestroy(this x: Obj): void { lockedUpdate(dead, (c: Count): Count => { return { n: c.n + 1 }; }); }

struct Pair { o: Obj; tag: string; }

function fail(why: string): Obj { throw new Error(why); }
function failPair(why: string): Pair { throw new Error(why); }

function pair(): string {
	try {
		const rs = await Promise.all([spawn((): Obj => new Obj(1)), spawn((): Obj => fail("second"))]);
		return `ok ${rs[0].v}`;
	} catch (e) { return "caught " + e.message; }
}

function middle(): string {
	try {
		const rs = await Promise.all([spawn((): Obj => new Obj(1)), spawn((): Obj => fail("middle")), spawn((): Obj => new Obj(3))]);
		return `ok ${rs[0].v}`;
	} catch (e) { return "caught " + e.message; }
}

function boxed(): string {
	try {
		const rs = await Promise.all([spawn((): Pair => ({ o: new Obj(1), tag: "a" })), spawn((): Pair => failPair("boxed")), spawn((): Pair => ({ o: new Obj(3), tag: "c" }))]);
		return `ok ${rs[0].tag}`;
	} catch (e) { return "caught " + e.message; }
}

async function asyncPair(): Promise<string> {
	try {
		const rs = await Promise.all([spawn((): Obj => new Obj(1)), spawn((): Obj => fail("async"))]);
		return `ok ${rs[0].v}`;
	} catch (e) { return "caught " + e.message; }
}

let last = "";
for (let i = 0; i < 20; i += 1) last = pair();
console.log(`pair ${last} destroyed=${deadCount()}`);
resetDead();
for (let i = 0; i < 20; i += 1) last = middle();
console.log(`middle ${last} destroyed=${deadCount()}`);
resetDead();
for (let i = 0; i < 20; i += 1) last = boxed();
console.log(`boxed ${last} destroyed=${deadCount()}`);
resetDead();
for (let i = 0; i < 20; i += 1) last = await asyncPair();
console.log(`async ${last} destroyed=${deadCount()}`);
