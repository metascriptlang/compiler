// @stdout: out-param heap write done

// Writing a heap value through an out/ref param must run the type's sink hook
// (destroy old, take new). A raw store leaves the caller's slot pointing at the
// temp's payload, which the callee then frees — use-after-free at the next read.
// The DRC ledger stays balanced here (alloc N, destroy N), so only the ASan lane
// catches a regression.

function setStr(out s: string, n: string): void { s = "w-" + n; }
function setNested(out outer: string, ref inner: string): void {
	inner = inner + "-x";
	outer = inner + "-outer";
}

function main(): void {
	let s: string = "orig";
	let i: int32 = 0;
	while (i < 2000) {
		setStr(out s, "abcdefghij-abcdefghij-abcdefghij");
		i = i + 1;
	}
	if (s.length != 34) { console.log("FAIL setStr len=" + s.length); return; }

	let a: string = "seed";
	let b: string = "base";
	let j: int32 = 0;
	while (j < 2000) {
		setNested(out a, b);
		j = j + 1;
	}
	if (a.length != b.length + 6) { console.log("FAIL setNested a=" + a.length + " b=" + b.length); return; }

	console.log("out-param heap write done");
}
main();
