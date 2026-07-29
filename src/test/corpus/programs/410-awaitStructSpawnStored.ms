// @ledger-slack(msRefArrayRefCell): 1
// @maxrss: 40
// @stdout: await-struct-spawn-stored acc=380000
// @serial
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Regression guard for the STORED-spawn-future path of the Amendment-F struct-future fix (the 3rd writer). spawn(structFn) whose result is STORED (array/variable) — not directly awaited — escapes both the fused AwaitGroup path and the _spawnSlotMap slot path and goes through lowerPromiseSpawn, which still allocated an INLINE future (msFutureCreateInline + msSpawnInto memcpy) for struct-like types while Amendment-F had moved BOTH readers (await deferred + waitFor) to BOXED (msWaitFor + msUnboxStruct) → the first 8 bytes of the inline struct value were read as a heap-box pointer → SIGSEGV (probe exit 139; before Amendment-F the same combo was silent-wrong under await). Fixed at the writer: lowerPromiseSpawn now follows the shared storage contract (util.ms inlineInFuture/boxedInFuture — hoisted there as the single source of truth so no 4th site can drift): only String keeps msSpawnInto inline; struct/tuple/GI fall to msSpawn, whose worker stores the closure's heap-box pointer in the void* slot — exactly what the boxed readers expect. acc=380000 (10000 batches × 4 spawns × (n 0..3 + "spawn-pt".length 8)); flat RSS proves box shells are freed. This SAME shape under ASAN-hammer (src/test/native/hammerAsan.sh) is the PARALOCK Amendment-G gate: the publish→push completion UAF only surfaces under ASAN + heavy iteration (a UAF write to freed-but-unreused memory is near-silent in a normal build), so this single normal-build entry guards Amendment-F but NOT Amendment-G — run hammerAsan.sh for the latter.

struct Pt { tag: string; n: number; }

function run(): void {
	let acc = 0;
	let batch = 0;
	while (batch < 10000) {
		const futs: Promise<Pt>[] = [];
		let k = 0;
		while (k < 4) {
			const kk = k;
			futs.push(spawn(() => { let m: Pt = { tag: "spawn-pt", n: kk }; return m; }));
			k = k + 1;
		}
		for (const f of futs) {
			const p = await f;
			acc = acc + p.n + p.tag.length;
		}
		batch = batch + 1;
	}
	console.log("await-struct-spawn-stored acc=" + acc.toString());
}

run();
