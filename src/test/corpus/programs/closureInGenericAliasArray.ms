// @stdout: t 6
interface Box { v: int32; }
type Fn<N> = (x: N) => int32;

function mkAlias<N>(k: int32): Fn<N>[] {
	const out: Fn<N>[] = [];
	out.push((x: N): int32 => k);
	return out;
}
function mkDirect<N>(k: int32): ((x: N) => int32)[] {
	const out: ((x: N) => int32)[] = [];
	out.push((x: N): int32 => k);
	return out;
}
function run(): void {
	const b: Box = { v: 1 };
	let t = 0;
	let u = 0;
	for (let i = 0; i < 4; i += 1) {
		const a = mkAlias<Box>(i);
		t = t + a[0](b);
		const d = mkDirect<Box>(i);
		u = u + d[0](b);
	}
	console.log("t " + t.toString());
	console.log("t " + u.toString());
}
run();
