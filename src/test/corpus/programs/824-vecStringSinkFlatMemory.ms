// @maxrss: 40
// @stdout: vec-string-sink 1 1005
// @xfail(raiser): the Raiser VM stops at its 10,000,000-iteration interpretation limit on this churn loop
function mk(i: int32): string {
	return "s".repeat(1000) + i.toString();
}

function run(n: int32): void {
	let v: Vec<string> = [mk(0)];
	for (let i: int32 = 0; i < n; i += 1) {
		v = [mk(i), mk(i + 1)];
		v = [mk(i)];
	}
	console.log(`vec-string-sink ${v.length} ${v[0].length}`);
}

run(100000);
