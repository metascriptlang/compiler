// @maxrss: 40
// @stdout: await-struct-in-async acc=1300000
// @serial
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Regression guard for the RESUME path of the Amendment-F struct-future fix (async fn awaiting a struct-returning async fn). `const s = await inner()` INSIDE an async function is read on the stepper resume path (asyncBridge, the readFnForAwait=='' branch), which previously used msWaitForStruct (INLINE) — correct when struct futures were inline, but after Amendment-F boxes async struct returns it read the boxed void* as an inline struct → silent WRONG value (probe gave 0 not 14). Found by the /audit pass — the direct-await guards (await-struct-returns) exercised the deferred sync-await reader, NOT the async-resume reader. Fixed by routing struct/tuple/GI + array on resume through msFutureRead + msUnboxStruct (boxed), matching the completion. acc=1300000 (100000 × (4 + "inner-tag".length 9)) proves the struct + its heap string round-trip through the async state machine; flat RSS proves no leak.

struct M { tag: string; n: number; }

async function inner(): Promise<M> { let m: M = { tag: "inner-tag", n: 4 }; return m; }

async function outer(): Promise<number> {
	const s = await inner();
	return s.n + s.tag.length;
}

function run(): void {
	let acc = 0;
	let i = 0;
	while (i < 100000) {
		acc = acc + await outer();
		i = i + 1;
	}
	console.log("await-struct-in-async acc=" + acc.toString());
}

run();
