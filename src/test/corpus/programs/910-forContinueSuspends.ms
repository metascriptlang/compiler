// @stdout: gen=0,0,2,20,3,4,40, async=24
function* gen(): Iterator<int32> {
	for (let i: int32 = 0; i < 5; i++) {
		if (i == 1) continue;
		yield i;
		if (i == 3) continue;
		yield i * 10;
	}
}

async function tick(x: int32): Promise<int32> { return x; }

async function run(): Promise<int32> {
	let acc: int32 = 0;
	for (let i: int32 = 0; i < 5; i++) {
		if (i == 1) continue;
		const v = await tick(i);
		if (v == 3) continue;
		acc = acc * 10 + v;
	}
	return acc;
}

function main(): void {
	let out = "";
	for (const v of gen()) { out = out + v.toString() + ","; }
	const r = await run();
	console.log(`gen=${out} async=${r}`);
}
main();
