// @stdout: task then 1
// @stdout: task captured 12
// @stdout: done 0
// note: a .then a spawned task registers keeps its callback and the value it receives until the callback runs, for a callback without an environment and one that captures.
async function one(): Promise<int32> { return 1; }

async function main(): Promise<void> {
	const h = spawn(() => {
		one().then((v: int32): void => { console.log(`task then ${v}`); });
		const base = 11;
		one().then((v: int32): void => { console.log(`task captured ${v + base}`); });
		return 0;
	});
	console.log(`done ${await h}`);
}

await main();
