// @stdout: seq 20000
// @stdout: chain 20000

let total = 0;

async function step(i: int32): Promise<int32> {
	const v = await spawn(() => i - i + 1);
	return v;
}

function chain(i: int32): void {
	step(i).then((v: int32): void => {
		total = total + v;
		if (i < 19999) {
			chain(i + 1);
		} else {
			console.log("chain " + total.toString());
		}
	});
}

async function main(): Promise<void> {
	let s = 0;
	for (let i = 0; i < 20000; i = i + 1) {
		const v = await spawn(() => 1);
		s = s + v;
	}
	console.log("seq " + s.toString());
	chain(0);
}
main();
