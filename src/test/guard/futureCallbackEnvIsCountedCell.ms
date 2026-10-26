// nim-guard: the env a .then/.catch/.finally parks on a future is a counted cell with a
// TypeInfo (destroyFn releases what it holds, traceFn visits it), the way a closure env is a
// ref cell the collector can trace. Raw malloc blocks have no ledger row at all.
//
// Reference: asyncfutures.nim CallbackList owns its closures (a ref chain, traced like any
// ref); liftdestructors.nim atomicClosureOp / attachedTrace for closures.
//
// Inert on its own: no future is a collector candidate yet, so this pins only that the envs
// are counted cells and balance on settled futures (each fired callback frees its cell).
//
// RED MEANS a Then/Catch/Finally env went back to a raw allocation or lost its TypeInfo, or
// a fire path stopped releasing it; read runtime/promise/combinator.h msFuture*EnvTypeInfo.
//
// GUARD-BALANCE msFutureThenEnv
// GUARD-BALANCE msFutureCatchEnv
// GUARD-BALANCE msFutureFinallyEnv
// GUARD-JS

class H { v: number = 1; }

function settled(): Promise<number> {
	return new Promise<number>((res) => { res(5); });
}

function settledText(): Promise<string> {
	return new Promise<string>((res) => { res("t"); });
}

function settledVoid(): Promise<void> {
	return new Promise<void>((res) => { res(); });
}

function failed(): Promise<void> {
	return new Promise<void>((res, rej) => { rej(new Error("boom")); });
}

let total: number = 0;

async function round(): Promise<void> {
	const local = new H();
	const s = "xyz";
	const all: Promise<void>[] = [];
	all.push(settled().then((x: number) => { total += x; }));
	all.push(settled().then((x: number) => { total += x + local.v; }));
	all.push(settled().then((x: number) => { total += x + s.length; }));
	all.push(settledText().then((x: string) => { total += x.length; }));
	all.push(settledText().then((x: string) => { total += x.length + local.v; }));
	all.push(settledVoid().then(() => { total += 1; }));
	all.push(settledVoid().then(() => { total += local.v; }));
	all.push(failed().then(() => { total += 1000; }, (e: Error) => { total += local.v; }));
	all.push(failed().catch((e: Error) => { total += 2; }));
	all.push(failed().catch((e: Error) => { total += local.v; }));
	all.push(failed().catch((e: Error) => { total += s.length; }));
	all.push(settledVoid().finally(() => { total += 3; }));
	all.push(settledVoid().finally(() => { total += local.v; }));
	all.push(settledVoid().finally(() => { total += s.length; }));
	for (const p of all) await p;
}

for (let i = 0; i < 20; i += 1) await round();
console.log(total);
console.log("GUARD-OK");
