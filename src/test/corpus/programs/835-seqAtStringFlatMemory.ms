// @maxrss: 40
// @stdout: seq-at-string 100000000 1001
function run(n: int32): void {
	const ss: string[] = ["s".repeat(1000), "t".repeat(1001)];
	let total: int64 = 0;
	for (let i: int32 = 0; i < n; i += 1) {
		const x = ss.at(0);
		total = total + x.length;
	}
	console.log(`seq-at-string ${total} ${ss.at(-1).length}`);
}

run(100000);
