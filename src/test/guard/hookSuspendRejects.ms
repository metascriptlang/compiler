// GUARD-JS
// ULTRALOCK T7: a lifecycle hook does not spawn, await or lend, directly or
// through a callee; a call through a function value counts as possible. Each
// shape is a compile error naming the call, on C and on JS. Shapes: spawn
// direct, through a callee, two callees deep, an (inert) function value, await
// direct, await through a callee, a lend of the receiver to a spawn; hook kinds:
// a receiver-function hook, a class method hook, a struct copy hook.
// RED MEANS: the hook effect in walkEffect (effects.ms) lost a shape, or a hook
// kind is no longer checked.
//
// GUARD-CHECK-FAIL it spawns at 25:
// GUARD-CHECK-FAIL it calls 'spawnHelper' at 29:
// GUARD-CHECK-FAIL it calls 'deep1' at 34:
// GUARD-CHECK-FAIL it calls a function value at 38:
// GUARD-CHECK-FAIL it awaits at 41:
// GUARD-CHECK-FAIL it calls 'awaitHelper' at 45:
// GUARD-CHECK-FAIL it spawns at 48:
// GUARD-CHECK-FAIL it calls 'spawnHelper' at 52:
// GUARD-CHECK-FAIL it calls 'deep1' at 56:

function work(n: int32): int32 { return n + 1; }
async function asy(n: int32): Promise<int32> { return n * 2; }

class SpawnDirect { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: SpawnDirect): void { const f = spawn(() => work(1)); console.log(`${await f}`); }

function spawnHelper(): int32 { return await spawn(() => work(1)); }
class SpawnCallee { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: SpawnCallee): void { console.log(`${spawnHelper()}`); }

function deep2(): int32 { return await spawn(() => work(2)); }
function deep1(): int32 { return deep2(); }
class SpawnDeep { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: SpawnDeep): void { console.log(`${deep1()}`); }

let inert: () => int32 = (): int32 => { return 5; };
class FnValue { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: FnValue): void { console.log(`${inert()}`); }

class AwaitDirect { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: AwaitDirect): void { console.log(`${await asy(x.v)}`); }

function awaitHelper(n: int32): int32 { return await asy(n); }
class AwaitCallee { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: AwaitCallee): void { console.log(`${awaitHelper(x.v)}`); }

class Lend { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: Lend): void { const f = spawn(() => work(x.v)); console.log(`${await f}`); }

class MethodHook {
	v: int32 = 1;
	onDestroy(): void { console.log(`${spawnHelper()}`); }
}

struct CopyHook { n: int32; }
function onCopy(this ref d: CopyHook, src: CopyHook): void { d.n = deep1() + src.n; }

function run(): void {
	const a = new SpawnDirect(1); const b = new SpawnCallee(2); const c = new SpawnDeep(3);
	const d = new FnValue(4); const e = new AwaitDirect(5); const f = new AwaitCallee(6);
	const g = new Lend(7); const h = new MethodHook();
	let p: CopyHook = { n: 1 }; const q: CopyHook = p;
	console.log(`${a.v + b.v + c.v + d.v + e.v + f.v + g.v + h.v + p.n + q.n}`);
}
run();
console.log("GUARD-OK");
