// @selftest-red none
// @stdout: spawn-join 600000
function work(k: int32): int32 {
	let n: int32 = 0;
	for (let i = 0; i < 1000; i++) n += k;
	return n;
}

async function main(): Promise<void> {
	let t: int32 = 0;
	for (let r = 0; r < 200; r++) {
		const a = spawn(() => work(1));
		const b = spawn(() => work(2));
		t += (await a) + (await b);
	}
	console.log(`spawn-join ${t}`);
}
main();
