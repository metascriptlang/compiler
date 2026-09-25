// @stdout: 10 20 30 0|0 1 0|12|11|4 3
// @xfail(raiser): the Raiser VM evaluates an assignment right side before the target index (`a[j] = j++` stores at j + 1)
function two(a: int32, b: int32): int32 {
	return a * 10 + b;
}
function run(): void {
	const src: int32[] = [10, 20, 30, 40];
	const dst: int32[] = [0, 0, 0, 0];
	let k: int32 = 0;
	while (k < 3) {
		dst[k] = src[k++];
	}
	const arr: int32[] = [0, 0, 0];
	let j: int32 = 1;
	arr[j] = j++;
	let i: int32 = 1;
	const r = two(i++, i);
	let m: int32 = 5;
	m = m++ + m;
	let w: int32 = 0;
	let n: int32 = 0;
	while (w++ < 3) { n = n + 1; }
	console.log(dst[0].toString() + " " + dst[1].toString() + " " + dst[2].toString() + " " + dst[3].toString()
		+ "|" + arr[0].toString() + " " + arr[1].toString() + " " + arr[2].toString()
		+ "|" + r.toString() + "|" + m.toString() + "|" + w.toString() + " " + n.toString());
	let z: int32 = 2;
	const trio = [z, --z, z];
	const keys: string[] = ["a", "b"];
	let at: int32 = 0;
	const picked = keys[at++] + keys[at];
	console.log(trio[0], trio[1], trio[2], picked);
}
run();
