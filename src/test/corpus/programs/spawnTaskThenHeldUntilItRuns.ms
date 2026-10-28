// @stdout: task sync
// @stdout: task then 1
// @stdout: task captured 12
// @stdout: done 0
// @xfail(danger): a .then registered in a spawn task runs at once on the worker, before the task's synchronous code, so 'task then' prints before 'task sync' (PARALOCK-runtime Amendment R)
// note: a .then a spawned task registers keeps its callback until the callback runs after the task's own code, for a callback without an environment and one that captures.
async function one(): Promise<int32> { return 1; }

async function main(): Promise<void> {
	const h = spawn(() => {
		one().then((v: int32): void => { console.log(`task then ${v}`); });
		const base = 11;
		one().then((v: int32): void => { console.log(`task captured ${v + base}`); });
		console.log("task sync");
		return 0;
	});
	console.log(`done ${await h}`);
}

await main();
