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
