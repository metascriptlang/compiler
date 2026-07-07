struct Msg { tag: string; n: number; }

async function amsg(): Promise<Msg> { let m: Msg = { tag: "async-tag", n: 7 }; return m; }

function run(): void {
	let acc = 0;
	let i = 0;
	while (i < 100000) {
		const q = await amsg();
		acc = acc + q.n + q.tag.length;
		i = i + 1;
	}
	console.log("await-struct-returns acc=" + acc.toString());
}

run();
