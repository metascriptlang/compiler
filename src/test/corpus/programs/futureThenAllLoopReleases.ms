// @stdout: acc 700000

async function one(n: number): Promise<number> {
	return n;
}

async function main(): Promise<void> {
	let acc: number = 0;
	for (let i = 0; i < 200000; i += 1) {
		const v = await one(i).then((x: number): number => x % 2);
		const pair = await Promise.all([one(1), one(2)]);
		acc = acc + v + pair[0] + pair[1];
	}
	console.log(`acc ${acc}`);
}

main();
