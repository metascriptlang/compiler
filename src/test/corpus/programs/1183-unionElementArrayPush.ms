// @stdout: 2 3 2 n7,sb,p3
// @stdout: 1 a null
// @stdout: 1,a
struct P { x: int32 }
function run(): void {
	const xs: (string | int32)[] = [];
	xs.push(1 as int32);
	xs.push("a");
	const ys: (string | int32 | P)[] = [];
	ys.push(7 as int32);
	ys.push("b");
	ys.push({ x: 3 });
	const zs: (string | null)[] = [];
	zs.push("q");
	zs.push(null);
	const out: string[] = [];
	for (const y of ys) {
		if (typeof y === "string") out.push("s" + y);
		else if (typeof y === "number") out.push("n" + y.toString());
		else out.push("p" + y.x.toString());
	}
	console.log(xs.length, ys.length, zs.length, out.join(","));
	console.log(xs[0], xs[1], zs[1]);
	console.log(xs);
}
run();
