// GUARD-JS
// ULTRALOCK T7 on a generic owner: a method hook of a generic class is checked
// like any other hook, so a spawn reached through a callee is a compile error
// naming the call.
// RED MEANS: the hook effect skips hooks whose owner is generic.
//
// GUARD-CHECK-FAIL lifecycle hook 'onDestroy' of 'Gen'
// GUARD-CHECK-FAIL it calls 'viaSpawn' at 16:

function work(n: int32): int32 { return n + 1; }
function viaSpawn(n: int32): int32 { const f = spawn(() => work(n)); return await f; }

class Gen<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	onDestroy(): void { console.log(`${viaSpawn(1)}`); }
}

function run(): void { const g = new Gen<int32>(1); console.log(`${g.v}`); }
run();
console.log("GUARD-OK");
