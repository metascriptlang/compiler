// @stdout: set: 2 a,b
// @stdout: numbers: 0,5,6,7,8
// @stdout: map: 2 j 2
// @stdout: map then literal: k y 3
// @stdout: rest: 2 3
// @stdout: generator: 1-2-3
// @stdout: last: x,a,b
type KV = [string, int32];
function count(...xs: string[]): int32 { return xs.length; }
function* gen(): Iterator<int32> { yield 1; yield 2; yield 3; }
function run(): void {
	const st = new Set<string>();
	st.add("a");
	st.add("b");
	const a: string[] = [...st];
	console.log("set: " + a.length.toString() + " " + a.join(","));
	const ns = new Set<int32>();
	ns.add(5);
	ns.add(6);
	ns.add(7);
	console.log("numbers: " + [0, ...ns, 8].join(","));
	const mp = new Map<string, int32>();
	mp.set("k", 1);
	mp.set("j", 2);
	const b: KV[] = [...mp];
	console.log("map: " + b.length.toString() + " " + b[1][0] + " " + b[1][1].toString());
	const c: KV[] = [...mp, ["y", 3]];
	console.log("map then literal: " + c[0][0] + " " + c[2][0] + " " + c[2][1].toString());
	console.log("rest: " + count(...st).toString() + " " + count("x", ...st).toString());
	console.log("generator: " + [...gen()].join("-"));
	console.log("last: " + ["x", ...st].join(","));
}
run();
