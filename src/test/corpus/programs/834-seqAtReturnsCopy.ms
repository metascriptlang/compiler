struct Named {
	name: string;
	n: int32;
}

class Holder {
	rows: string[][] = [];
}

function run(): void {
	let total: int32 = 0;
	for (let k: int32 = 0; k < 50; k++) {
		const ss: string[] = ["a" + k.toString(), "b"];
		const x = ss.at(0);
		const ns: Named[] = [{ name: "n" + k.toString(), n: k }, { name: "m", n: 1 }];
		const s = ns.at(0);
		const cs: Holder[] = [new Holder()];
		const c = cs.at(-1);
		c.rows.push(["r" + k.toString()]);
		const fs: (() => int32)[] = [() => c.rows.length as int32 + 1, () => 2];
		const f = fs.at(0);
		const n2: int32[][] = [[k], [2, 3]];
		const y = n2.at(0);
		const h = new Holder();
		h.rows.push(["a"]);
		h.rows.push(["b", "c" + k.toString()]);
		const r = h.rows.at(-1);
		total = total + x.length + s.name.length + s.n + c.rows.length + f() + y[0] + r.length;
		if (k == 49) {
			console.log(`${x} ${ss.at(-1)} ${s.name} ${ns.at(-1).name} ${cs.at(0).rows.at(0).at(0)} ${fs.at(-1)()} ${y.length} ${r.at(1)}`);
		}
	}
	console.log(`total=${total}`);
}

run();
