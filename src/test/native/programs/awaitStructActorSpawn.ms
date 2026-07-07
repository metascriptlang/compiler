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
