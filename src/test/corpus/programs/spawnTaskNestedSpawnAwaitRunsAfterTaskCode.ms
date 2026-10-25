// @serial

class Box { n: int64 = 0; }

async function bump(b: Box, one: Box): Promise<void> {
	await spawn(() => 1);
	for (let i = 0; i < 3000000; i++) b.n += one.n;
}

async function main(): Promise<void> {
	const hs: Promise<int64>[] = [];
	for (let j = 0; j < 4; j++) {
		hs.push(spawn(() => {
			const b = new Box();
			const one = new Box();
			one.n = 1;
			const p = bump(b, one);
			for (let i = 0; i < 3000000; i++) b.n += one.n;
			await p;
			return b.n;
		}));
	}
	for (const h of hs) {
		console.log(`n ${await h}`);
	}
}

main();
