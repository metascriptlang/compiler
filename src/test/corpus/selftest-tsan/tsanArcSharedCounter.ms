// @selftest-red none
// @stdout: arc-shared 3200
struct Payload { n: int32; }

function fetchShared(a: Arc<Payload>): Arc<Payload> { return a; }

async function main(): Promise<void> {
	const a: Arc<Payload> = new Arc({ n: 4 });
	let total = 0;
	for (let round = 0; round < 200; round++) {
		const h1 = spawn(() => fetchShared(a));
		const h2 = spawn(() => fetchShared(a));
		const r1 = await h1;
		const r2 = await h2;
		total = total + r1.n + r2.n;
	}
	console.log(`arc-shared ${total * 2}`);
}
main();
