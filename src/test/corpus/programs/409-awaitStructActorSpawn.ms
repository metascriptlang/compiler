// @maxrss: 40
// @stdout: await-struct-actorspawn acc=2600000
// @serial
// note: GREEN regression guard for the struct-future-layout fix (paired with the RED await-struct-returns). `await` on a struct-with-heap-field (tag: string) return from an actor CALL and from spawn — both BOXED (msSinkBoxStruct → msMsgCompletePtr / spawn box), read by awaitLower's msWaitFor(void*)+msUnboxStruct. Locks the actor/spawn boxed path so the Amendment-F fix (boxing async struct returns) can't silently regress them — the DRC-ownership-transfer surface where a heap string double-frees or leaks if the box mishandles it. acc=2600000 (100000 × ((5+9)+(3+9))).

struct Msg { tag: string; n: number; }

actor Svc {
	getM(): Msg { let m: Msg = { tag: "actor-tag", n: 5 }; return m; }
}

function run(): void {
	const svc = new Svc();
	let acc = 0;
	let i = 0;
	while (i < 100000) {
		const c = await svc.getM();
		acc = acc + c.n + c.tag.length;
		const s = await spawn(() => { let m: Msg = { tag: "spawn-tag", n: 3 }; return m; });
		acc = acc + s.n + s.tag.length;
		i = i + 1;
	}
	console.log("await-struct-actorspawn acc=" + acc.toString());
}

run();
