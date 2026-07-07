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
