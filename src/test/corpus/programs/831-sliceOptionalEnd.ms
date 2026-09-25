class Box { v: int32 = 0; }

function run(): void {
	const t: int32[] = [1, 2, 3];
	const u = t.slice(1);
	console.log(`int32 ${u.length} ${u[0]} ${t.slice(-1)[0]}`);
	const n: number[] = [1.5, 2.5, 3.5];
	console.log(`number ${n.slice(2).length} ${n.slice(-2)[0]}`);
	const w: string[] = ["a", "b", "c"];
	console.log(`string[] ${w.slice(1).join(",")} ${w.slice(3).length}`);
	const b: Box[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		const x = new Box();
		x.v = i;
		b.push(x);
	}
	console.log(`class ${b.slice(1).length} ${b.slice(-1)[0].v}`);
	const s = "hello";
	console.log(`string ${s.slice(2)} ${s.slice(-1)} ${s.slice(1, 3)}`);
}

run();
