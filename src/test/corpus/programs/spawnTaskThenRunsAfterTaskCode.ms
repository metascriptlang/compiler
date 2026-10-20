// @xfail(c): a .then registered in a spawn task runs at once on the worker, before the task's synchronous code, so 'task then' prints before 'task sync' (PARALOCK-runtime Amendment R)
// @xfail(orc): a .then registered in a spawn task runs at once on the worker, before the task's synchronous code, so 'task then' prints before 'task sync' (PARALOCK-runtime Amendment R)
// @xfail(danger): a .then registered in a spawn task runs at once on the worker, before the task's synchronous code, so 'task then' prints before 'task sync' (PARALOCK-runtime Amendment R)
// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen

async function one(): Promise<int32> { return 1; }

async function main(): Promise<void> {
	const h = spawn(() => {
		one().then((v: int32): void => { console.log("task then"); });
		console.log("task sync");
		return 0;
	});
	await h;
	one().then((v: int32): void => { console.log("main then"); });
	console.log("main sync");
}

main();
